#include "internal.h"
#include "arch.h"
#include "memory.h"

#if TARGET == x86_64
#define ENSURE_PD_EXISTS(pd, pd_entry)					\
  if ( !(pd_entry) ) {							\
    /* There is no page here, so we need to allocate */			\
    (pd_entry) = (uintptr_t) MEM_ALLOC(allocator);			\
    (pd_entry) |= 3;							\
    									\
    ARCH_INVALIDATE_PAGE(pd);						\
    memset(pd, 0, ARCH_PAGE_SIZE);					\
  }

void klog (const char *c);

void arch_map_page(mem_allocator_t *allocator, uintptr_t virt, uintptr_t phys)
{
  int pml4_entry = PML4_ENTRY(virt),
    pdpt_entry = PDPT_ENTRY(virt),
    pdt_entry = PDT_ENTRY(virt),
    pt_entry = PT_ENTRY(virt);

  uintptr_t *pml4 = (uintptr_t *) CUR_PML4_ADDR,
    *pdpt = (uintptr_t *) CUR_PDPT_ADDR(pml4_entry),
    *pdt = (uintptr_t *) CUR_PDT_ADDR(pml4_entry, pdpt_entry),
    *pt = (uintptr_t *) CUR_PT_ADDR(pml4_entry, pdpt_entry, pdt_entry);

  ENSURE_PD_EXISTS(pdpt, pml4[pml4_entry]);
  ENSURE_PD_EXISTS(pdt, pdpt[pdpt_entry]);
  ENSURE_PD_EXISTS(pt, pdt[pdt_entry]);

  pt[pt_entry] = phys | 3;
  ARCH_INVALIDATE_PAGE(virt);
}

void arch_mark_user(uintptr_t virt)
{
  int pml4_entry = PML4_ENTRY(virt),
    pdpt_entry = PDPT_ENTRY(virt),
    pdt_entry = PDT_ENTRY(virt),
    pt_entry = PT_ENTRY(virt);

  uintptr_t *pml4 = (uintptr_t *) CUR_PML4_ADDR,
    *pdpt = (uintptr_t *) CUR_PDPT_ADDR(pml4_entry),
    *pdt = (uintptr_t *) CUR_PDT_ADDR(pml4_entry, pdpt_entry),
    *pt = (uintptr_t *) CUR_PT_ADDR(pml4_entry, pdpt_entry, pdt_entry);

  if (!pml4[pml4_entry]) return;
  if (!pdpt[pdpt_entry]) return;
  if (!pdt[pdt_entry]) return;

  pml4[pml4_entry] |= 4;
  pdpt[pdpt_entry] |= 4;
  pdt[pdt_entry] |= 4;
  pt[pt_entry] |= 4;
}

uintptr_t arch_unmap_page(uintptr_t virt)
{
  int pml4_entry = PML4_ENTRY(virt),
    pdpt_entry = PDPT_ENTRY(virt),
    pdt_entry = PDT_ENTRY(virt),
    pt_entry = PT_ENTRY(virt);

  uintptr_t *pml4 = (uintptr_t *) CUR_PML4_ADDR,
    *pdpt = (uintptr_t *) CUR_PDPT_ADDR(pml4_entry),
    *pdt = (uintptr_t *) CUR_PDT_ADDR(pml4_entry, pdpt_entry),
    *pt = (uintptr_t *) CUR_PT_ADDR(pml4_entry, pdpt_entry, pdt_entry);

  uintptr_t old_phys;

  if (!pml4[pml4_entry]) return 0;
  if (!pdpt[pdpt_entry]) return 0;
  if (!pdt[pdt_entry]) return 0;

  old_phys = pt[pt_entry];
  pt[pt_entry] = 0;

  if (old_phys) ARCH_INVALIDATE_PAGE(old_phys);

  return PAGE_ADDR(old_phys);
}

uintptr_t arch_get_phys_page(uintptr_t virt)
{
  int pml4_entry = PML4_ENTRY(virt),
    pdpt_entry = PDPT_ENTRY(virt),
    pdt_entry = PDT_ENTRY(virt),
    pt_entry = PT_ENTRY(virt);

  uintptr_t *pml4 = (uintptr_t *) CUR_PML4_ADDR,
    *pdpt = (uintptr_t *) CUR_PDPT_ADDR(pml4_entry),
    *pdt = (uintptr_t *) CUR_PDT_ADDR(pml4_entry, pdpt_entry),
    *pt = (uintptr_t *) CUR_PT_ADDR(pml4_entry, pdpt_entry, pdt_entry);

  if (!pml4[pml4_entry]) return 0;
  if (!pdpt[pdpt_entry]) return 0;
  if (!pdt[pdt_entry]) return 0;

  return PAGE_ADDR(pt[pt_entry]);
}

void report_sse_panic()
{
  klog("The kernel panicked because it attempted to steal userspace state from Haskell-land\n");
  for(;;) asm("hlt");
}

extern int stack_unmap, stack_bottom;
void report_kernel_panic(uint64_t trap, uint64_t err_code, uint64_t rip, uint64_t rflags)
{
  klog("The kernel panicked on trap number ");
  klog_hex(trap);
  klog(".\n The error code was ");
  klog_hex(err_code);
  klog(".\n We were at RIP ");
  klog_hex(rip);
  if ( (trap & 0xff) == 14) {
    uint64_t access;
    asm("mov %%cr2, %%rax" : "=a"(access));
    klog(".\n The access was ");
    klog_hex(access);
    if (access >= ((uintptr_t) &stack_unmap) && access < ((uintptr_t) &stack_bottom)) {
      klog(". This means the access was a STACK OVERFLOW\n");
    }
  }

  uint64_t *userspaceState = (uint64_t *)(((uintptr_t)&kernelState) + 8);
  klog("Registers:\n");
  klog("RAX=");
  klog_hex(userspaceState[0]);
  klog(" RBX=");
  klog_hex(userspaceState[1]);
  klog(" RCX=");
  klog_hex(userspaceState[2]);
  klog(" RDX=");
  klog_hex(userspaceState[3]);
  klog("\nRSI=");
  klog_hex(userspaceState[4]);
  klog(" RDI=");
  klog_hex(userspaceState[5]);
  klog(" R8=");
  klog_hex(userspaceState[6]);
  klog(" R9=");
  klog_hex(userspaceState[7]);
  klog("\nR10=");
  klog_hex(userspaceState[8]);
  klog(" R11=");
  klog_hex(userspaceState[9]);
  klog(" R12=");
  klog_hex(userspaceState[10]);
  klog(" R13=");
  klog_hex(userspaceState[11]);
  klog("\nR14=");
  klog_hex(userspaceState[12]);
  klog(" R15=");
  klog_hex(userspaceState[13]);

  klog("\nRIP=");
  klog_hex(rip);
  klog(" RSP=");
  klog_hex(userspaceState[15]);
  klog(" RBP=");
  klog_hex(userspaceState[16]);
  klog(" RFLAGS=");
  klog_hex(rflags);

  asm("cli\nhlt");
}

#endif
