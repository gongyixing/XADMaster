#import "PPMdSubAllocator.h"

typedef struct PPMdMemoryBlockVariantI
{
	uint32_t Stamp;
	struct PPMdMemoryBlockVariantI *next; // 64-bit issues!
	uint32_t NU;
} __attribute__((packed)) PPMdMemoryBlockVariantI;

typedef struct PPMdSubAllocatorVariantI
{
	PPMdSubAllocator core;

	uint32_t GlueCount,SubAllocatorSize;
	uint8_t Index2Units[38],Units2Index[128]; // constants
	uint8_t *pText,*UnitsStart,*LowUnit,*HighUnit;
	PPMdMemoryBlockVariantI BList[38];
	uint8_t HeapStart[0];
} PPMdSubAllocatorVariantI;

PPMdSubAllocatorVariantI *CreateSubAllocatorVariantI(int size);
void FreeSubAllocatorVariantI(PPMdSubAllocatorVariantI *self);

uint32_t GetUsedMemoryVariantI(PPMdSubAllocatorVariantI *self);
void SpecialFreeUnitVariantI(PPMdSubAllocatorVariantI *self,uint32_t offs);
uint32_t MoveUnitsUpVariantI(PPMdSubAllocatorVariantI *self,uint32_t oldoffs,int num);
void ExpandTextAreaVariantI(PPMdSubAllocatorVariantI *self);
