/*
 * Copyright 2020, Data61, CSIRO (ABN 41 687 119 230)
 * Copyright 2021, HENSOLDT Cyber
 *
 * SPDX-License-Identifier: GPL-2.0-only
 */

#include <config.h>
#include <machine/assembler.h>
#include <arch/machine/hardware.h>
#include <arch/machine/registerset.h>
#include <util.h>

#ifndef ALLOW_UNALIGNED_ACCESS
#define ALLOW_UNALIGNED_ACCESS 1
#endif

#if ALLOW_UNALIGNED_ACCESS
#define CR_ALIGN_SET     0
#define CR_ALIGN_CLEAR   BIT(CONTROL_A)
#else
#define CR_ALIGN_SET     BIT(CONTROL_A)
#define CR_ALIGN_CLEAR   0
#endif

#if defined(CONFIG_ARM_HYPERVISOR_SUPPORT) && defined(CONFIG_AARCH64_USER_CACHE_ENABLE)
#define CR_USER_CACHE_OPS_SET (BIT(CONTROL_UCT) | BIT(CONTROL_UCI))
#define CR_USER_CACHE_OPS_CLEAR 0
#else
#define CR_USER_CACHE_OPS_SET 0
#define CR_USER_CACHE_OPS_CLEAR (BIT(CONTROL_UCT) | BIT(CONTROL_UCI))
#endif

#ifndef CONFIG_DEBUG_DISABLE_L1_ICACHE
    #define CR_L1_ICACHE_SET   BIT(CONTROL_I)
    #define CR_L1_ICACHE_CLEAR 0
#else
    #define CR_L1_ICACHE_SET   0
    #define CR_L1_ICACHE_CLEAR BIT(CONTROL_I)
#endif

#ifndef CONFIG_DEBUG_DISABLE_L1_DCACHE
    #define CR_L1_DCACHE_SET   BIT(CONTROL_C)
    #define CR_L1_DCACHE_CLEAR 0
#else
    #define CR_L1_DCACHE_SET   0
    #define CR_L1_DCACHE_CLEAR BIT(CONTROL_C)
#endif

#define CR_BITS_SET    (CR_ALIGN_SET | \
                        CR_L1_ICACHE_SET | \
                        CR_L1_DCACHE_SET | \
                        CR_USER_CACHE_OPS_SET | \
                        BIT(CONTROL_M))

#define CR_BITS_CLEAR  (CR_ALIGN_CLEAR | \
                        CR_L1_ICACHE_CLEAR | \
                        CR_L1_DCACHE_CLEAR | \
                        CR_USER_CACHE_OPS_CLEAR | \
                        BIT(CONTROL_SA0) | \
                        BIT(CONTROL_EE) | \
                        BIT(CONTROL_E0E))

/*
 * Entry point of the kernel ELF image.
 * X0-X5 contain parameters that are passed to init_kernel().
 *
 * Note that for SMP kernel, the tpidr_el1 is used to pass
 * the logical core ID.
 */

#ifdef CONFIG_ARM_HYPERVISOR_SUPPORT
#define SCTLR   sctlr_el2
#else
#define SCTLR   sctlr_el1
#endif

.section .boot.text
BEGIN_FUNC(_start)
    /* Save x4, x5, x6, x7 so we don't clobber it */
    mov     x14, x4
    mov     x15, x5
    mov     x16, x6
    mov     x17, x7

    /* Make sure interrupts are disabled */
    msr daifset, #DAIFSET_MASK

    /* Initialise sctlr_el1 or sctlr_el2 register */
    msr     spsel, #1
    mrs     x4, SCTLR
    ldr     x19, =CR_BITS_SET
    ldr     x20, =CR_BITS_CLEAR
    orr     x4, x4, x19
    bic     x4, x4, x20
    msr     SCTLR, x4

#ifdef ENABLE_SMP_SUPPORT
    /* tpidr_el1 has the logic ID of the core, starting from 0 */
    mrs     x6, tpidr_el1
    /* Set the sp for each core assuming linear indices */
    ldr     x5, =BIT(CONFIG_KERNEL_STACK_BITS)
    mul     x5, x5, x6
    ldr     x4, =kernel_stack_alloc + BIT(CONFIG_KERNEL_STACK_BITS)
    add     x4, x4, x5
    mov     sp, x4
    /* the kernel stack must be 4-KiB aligned since we use the
       lowest 12 bits to store the logical core ID. */
    orr     x6, x6, x4
#ifdef CONFIG_ARM_HYPERVISOR_SUPPORT
    msr     tpidr_el2, x6
#else
    msr     tpidr_el1, x6
#endif
#else
    ldr    x4, =kernel_stack_alloc + BIT(CONFIG_KERNEL_STACK_BITS)
    mov    sp, x4
#endif /* ENABLE_SMP_SUPPORT */

    /* Attempt to workaround any known ARM errata. */
    stp     x0, x1, [sp, #-16]!
    stp     x2, x3, [sp, #-16]!
    stp     x14, x15, [sp, #-16]!
    stp     x16, x17, [sp, #-16]!
    bl arm_errata
    ldp     x6, x7, [sp], #16
    ldp     x4, x5, [sp], #16
    ldp     x2, x3, [sp], #16
    ldp     x0, x1, [sp], #16

    /* Call bootstrapping implemented in C with parameters:
     *  x0: user image physical start address
     *  x1: user image physical end address
     *  x2: physical/virtual offset
     *  x3: user image virtual entry address
     *  x4: DTB physical address (0 if there is none)
     *  x5: DTB size (0 if there is none)
     *  x6: extra device memory region (0 if there is none)
     *  x7: extra device size (0 if there is none)
     */
    bl      init_kernel

    /* Restore the initial thread. Note that the function restore_user_context()
     * could technically also be called at the end of init_kernel() directly,
     * there is no need to return to the assembly code here at all. However, for
     * verification things are a lot easier when init_kernel() is a normal C
     * function that returns. The function restore_user_context() is not a
     * normal C function and thus handled specially in verification, it does
     * highly architecture specific things to exit to user mode.
     */
    b restore_user_context

END_FUNC(_start)
