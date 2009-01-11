#import "PPMdSubAllocatorVariantH.h"

#include <stdlib.h>
#include <string.h>

#define N1 4
#define N2 4
#define N3 4
#define N4 ((128+3-1*N1-2*N2-3*N3)/4)
#define UNIT_SIZE 12
#define N_INDEXES (N1+N2+N3+N4)

struct PPMdMemoryBlock
{
	uint16_t Stamp,NU;
	struct PPMdMemoryBlock *next,*prev; // 64-bit issues!
} __attribute__((packed));

static inline void InsertBlockAt(struct PPMdMemoryBlock *self,struct PPMdMemoryBlock *p)
{
	self->prev=p;
	self->next=p->next;
	self->next->prev=self;
	self->prev->next=self;
}

void RemoveBlock(struct PPMdMemoryBlock *self)
{
	self->prev->next=self->next;
	self->next->prev=self->prev;
}

static void InsertNode(PPMdSubAllocatorVariantH *self,void *p,int index);
static void *RemoveNode(PPMdSubAllocatorVariantH *self,int index);
static unsigned int I2B(PPMdSubAllocatorVariantH *self,int index);
static void SplitBlock(PPMdSubAllocatorVariantH *self,void *pv,int oldindex,int newindex);
static uint32_t GetUsedMemory(PPMdSubAllocatorVariantH *self);

static void InitVariantH(PPMdSubAllocatorVariantH *self);
static uint32_t AllocContextVariantH(PPMdSubAllocatorVariantH *self);
static uint32_t AllocUnitsVariantH(PPMdSubAllocatorVariantH *self,int num);
static uint32_t _AllocUnits(PPMdSubAllocatorVariantH *self,int index);
static uint32_t ExpandUnitsVariantH(PPMdSubAllocatorVariantH *self,uint32_t oldoffs,int oldnum);
static uint32_t ShrinkUnitsVariantH(PPMdSubAllocatorVariantH *self,uint32_t oldoffs,int oldnum,int newnum);
static void FreeUnitsVariantH(PPMdSubAllocatorVariantH *self,uint32_t offs,int num);

static inline void GlueFreeBlocks(PPMdSubAllocatorVariantH *self);

static inline void *_OffsetToPointer(PPMdSubAllocatorVariantH *self,uint32_t offset) { return ((uint8_t *)self)+offset; }
static inline uint32_t _PointerToOffset(PPMdSubAllocatorVariantH *self,void *pointer) { return ((uintptr_t)pointer)-(uintptr_t)self; }




PPMdSubAllocatorVariantH *CreateSubAllocatorVariantH(int size)
{
	PPMdSubAllocatorVariantH *self=malloc(sizeof(PPMdSubAllocatorVariantH)+size);
	if(!self) return NULL;

	self->core.Init=(void *)InitVariantH;
	self->core.AllocContext=(void *)AllocContextVariantH;
	self->core.AllocUnits=(void *)AllocUnitsVariantH;
	self->core.ExpandUnits=(void *)ExpandUnitsVariantH;
	self->core.ShrinkUnits=(void *)ShrinkUnitsVariantH;
	self->core.FreeUnits=(void *)FreeUnitsVariantH;

    self->SubAllocatorSize=size;

	return self;
}

void FreeSubAllocatorVariantH(PPMdSubAllocatorVariantH *self)
{
	free(self);
}



static void InitVariantH(PPMdSubAllocatorVariantH *self)
{
	memset(self->FreeList,0,sizeof(self->FreeList));

	self->pText=self->HeapStart;
	self->HighUnit=self->HeapStart+self->SubAllocatorSize;
	unsigned int diff=UNIT_SIZE*(self->SubAllocatorSize/8/UNIT_SIZE*7);
	self->LowUnit=self->UnitsStart=self->HighUnit-diff;
	self->GlueCount=0;

	for(int i=0;i<N1;i++) self->Index2Units[i]=1+i;
    for(int i=0;i<N2;i++) self->Index2Units[N1+i]=2+N1+i*2;
    for(int i=0;i<N3;i++) self->Index2Units[N1+N2+i]=3+N1+2*N2+i*3;
	for(int i=0;i<N4;i++) self->Index2Units[N1+N2+N3+i]=4+N1+2*N2+3*N3+i*4;

	int i=0;
    for(int k=0;k<128;k++)
	{
        if(self->Index2Units[i]<k+1) i++;
		self->Units2Index[k]=i;
    }
}

static uint32_t AllocContextVariantH(PPMdSubAllocatorVariantH *self)
{
    if(self->HighUnit!=self->LowUnit)
	{
		self->HighUnit-=UNIT_SIZE;
		return _PointerToOffset(self,self->HighUnit);
	}

	if(self->FreeList->next) return _PointerToOffset(self,RemoveNode(self,0));
 
    return _AllocUnits(self,0);
}

static uint32_t AllocUnitsVariantH(PPMdSubAllocatorVariantH *self,int num)
{
	int index=self->Units2Index[num-1];

	if(self->FreeList[index].next) return _PointerToOffset(self,RemoveNode(self,index));

	void *units=self->LowUnit;
	self->LowUnit+=I2B(self,index);
	if(self->LowUnit<=self->HighUnit) return _PointerToOffset(self,units);

	self->LowUnit-=I2B(self,index);

	return _AllocUnits(self,index);
}

static uint32_t _AllocUnits(PPMdSubAllocatorVariantH *self,int index)
{
	if(self->GlueCount==0)
	{
		self->GlueCount=255;
		GlueFreeBlocks(self);
		if(self->FreeList[index].next) return _PointerToOffset(self,RemoveNode(self,index));
	}

	for(int i=index+1;i<N_INDEXES;i++)
	{
		if(self->FreeList[i].next)
		{
			void *units=RemoveNode(self,i);
			SplitBlock(self,units,i,index);
			return _PointerToOffset(self,units);
		}
	}

	self->GlueCount--;

	int i=I2B(self,index);
	if(self->UnitsStart-self->pText>i)
	{
		self->UnitsStart-=i;
		return _PointerToOffset(self,self->UnitsStart);
	}

	return 0;
}

static uint32_t ExpandUnitsVariantH(PPMdSubAllocatorVariantH *self,uint32_t oldoffs,int oldnum)
{
	void *oldptr=_OffsetToPointer(self,oldoffs);
	int oldindex=self->Units2Index[oldnum-1];
	int newindex=self->Units2Index[oldnum];
	if(oldindex==newindex) return oldoffs;

	uint32_t offs=AllocUnitsVariantH(self,oldnum+1);
	if(offs)
	{
		memcpy(_OffsetToPointer(self,offs),oldptr,oldnum*UNIT_SIZE);
		InsertNode(self,oldptr,oldindex);
	}
	return offs;
}

static uint32_t ShrinkUnitsVariantH(PPMdSubAllocatorVariantH *self,uint32_t oldoffs,int oldnum,int newnum)
{
	void *oldptr=_OffsetToPointer(self,oldoffs);
	int oldindex=self->Units2Index[oldnum-1];
	int newindex=self->Units2Index[newnum-1];
	if(oldindex==newindex) return oldoffs;

	if(self->FreeList[newindex].next)
	{
		void *ptr=RemoveNode(self,newindex);
		memcpy(ptr,oldptr,newnum*UNIT_SIZE);
		InsertNode(self,oldptr,oldindex);
		return _PointerToOffset(self,ptr);
	}
	else
	{
		SplitBlock(self,oldptr,oldindex,newindex);
		return oldoffs;
    }
}

static void FreeUnitsVariantH(PPMdSubAllocatorVariantH *self,uint32_t offs,int num)
{
	InsertNode(self,_OffsetToPointer(self,offs),self->Units2Index[num-1]);
}



static inline void GlueFreeBlocks(PPMdSubAllocatorVariantH *self)
{
	struct PPMdMemoryBlock s0;
	if(self->LowUnit!=self->HighUnit) *self->LowUnit=0;

	s0.next=s0.prev=&s0;
	for(int i=0;i<N_INDEXES;i++)
	{
		while(self->FreeList[i].next)
		{
			struct PPMdMemoryBlock* p=(struct PPMdMemoryBlock *)RemoveNode(self,i);
			InsertBlockAt(p,&s0);
			p->Stamp=0xFFFF;
			p->NU=self->Index2Units[i];
		}
	}

	for(struct PPMdMemoryBlock *p=s0.next;p!=&s0;p=p->next)
	{
		for(;;)
		{
			struct PPMdMemoryBlock *p1=p+p->NU;

			if(p1->Stamp!=0xFFFF) break;
			if(p->NU+p1->NU>=0x10000) break;

			RemoveBlock(p1);
			p->NU+=p1->NU;
		}
	}

	for(;;)
	{
		struct PPMdMemoryBlock *p=s0.next;
		if(p==&s0) break;
		RemoveBlock(p);

		int sz=p->NU;
		while(sz>128)
		{
			InsertNode(self,p,N_INDEXES-1);
			sz-=128;
			p+=128;
		}

		int i=self->Units2Index[sz-1];
		if(self->Index2Units[i]!=sz)
		{
			i--;
			int k=sz-self->Index2Units[i];
			InsertNode(self,p+(sz-k),k-1);
		}
		InsertNode(self,p,i);
	}
}



static void InsertNode(PPMdSubAllocatorVariantH *self,void *p,int index)
{
	((struct PPMAllocatorNodeVariantH *)p)->next=self->FreeList[index].next;
	self->FreeList[index].next=p;
}

static void *RemoveNode(PPMdSubAllocatorVariantH *self,int index)
{
	struct PPMAllocatorNodeVariantH *node=self->FreeList[index].next;
	self->FreeList[index].next=node->next;
	return node;
}

static inline unsigned int I2B(PPMdSubAllocatorVariantH *self,int index) { return UNIT_SIZE*self->Index2Units[index]; }

static void SplitBlock(PPMdSubAllocatorVariantH *self,void *pv,int oldindex,int newindex)
{
	uint8_t *p=((uint8_t *)pv)+I2B(self,newindex);

	int diff=self->Index2Units[oldindex]-self->Index2Units[newindex];
	int i=self->Units2Index[diff-1];
	if(self->Index2Units[i]!=diff)
	{
		InsertNode(self,p,i-1);
		p+=I2B(self,i-1);
        diff-=self->Index2Units[i-1];
    }

    InsertNode(self,p,self->Units2Index[diff-1]);
}

static uint32_t GetUsedMemory(PPMdSubAllocatorVariantH *self)
{
	uint32_t size=self->SubAllocatorSize-(self->HighUnit-self->LowUnit)-(self->UnitsStart-self->pText);

	for(int i=0;i<N_INDEXES;i++)
	{
		int k=0;
		struct PPMAllocatorNodeVariantH *node=&self->FreeList[i];
		while(node=node->next) k++;

		size-=UNIT_SIZE*self->Index2Units[i]*k;
    }

    //if(self->LastBreath) size-=128*128*UNIT_SIZE;

	return size>>2;
}
