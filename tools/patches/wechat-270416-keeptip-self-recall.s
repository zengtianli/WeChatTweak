// WeChat 4.2.0 / build 270416 / arm64 only.
//
// config.json branches from 0x46676fc here (branch bytes FFB44814). The final
// instruction returns to 0x4667700. This routine replaces the parser's
// `eor w19, w20, #1` at the hook site, so it must replay that instruction.
//
// Register facts at the hook site, confirmed in the pristine wechat.dylib:
//   x19 = parsed message structure (newmsgid at +0x1c8)
//   x20 = parser status used by the original eor
//   x21 = original revoke XML std::string
//
// Preserve the real newmsgid when the XML contains a self-recall marker. For
// other recalls, write zero as the existing keeptip patch did. The string
// layout follows the libc++ short/long representation used by this binary.

.text
.p2align 2
.globl _payload
_payload:
    ldrsb   w8, [x21, #0x17]
    tbnz    w8, #31, .Llong
    mov     x10, x21
    ldrb    w11, [x21, #0x17]
    b       .Lscan
.Llong:
    ldr     x10, [x21]
    ldr     x11, [x21, #8]
.Lscan:
    add     x12, x10, x11
    mov     x13, x10
.Lloop:
    sub     x9, x12, x13
    cmp     x9, #9
    b.lo    .Lnotself
    ldrb    w8, [x13]
    cmp     w8, #0xe4
    b.eq    .Lchinese
    cmp     w8, #0x59
    b.eq    .Lenglish
.Lnext:
    add     x13, x13, #1
    b       .Lloop
.Lchinese:
    ldrb    w8, [x13, #1]
    cmp     w8, #0xbd
    b.ne    .Lnext
    ldrb    w8, [x13, #2]
    cmp     w8, #0xa0
    b.ne    .Lnext
    ldrh    w8, [x13, #3]
    mov     w9, #0x92e6
    cmp     w8, w9
    b.eq    .Lni_che
    mov     w9, #0x94e6
    cmp     w8, w9
    b.eq    .Lni_shou
    mov     w9, #0x9be5
    cmp     w8, w9
    b.ne    .Lnext
    // 你回收
    ldrb    w8, [x13, #5]
    cmp     w8, #0x9e
    b.ne    .Lnext
    ldrb    w8, [x13, #6]
    cmp     w8, #0xe6
    b.ne    .Lnext
    ldrb    w8, [x13, #7]
    cmp     w8, #0x94
    b.ne    .Lnext
    ldrb    w8, [x13, #8]
    cmp     w8, #0xb6
    b.eq    .Lself
    b       .Lnext
.Lni_che:
    ldrb    w8, [x13, #5]
    cmp     w8, #0xa4
    b.ne    .Lnext
    b       .Lcheck_hui
.Lni_shou:
    ldrb    w8, [x13, #5]
    cmp     w8, #0xb6
    b.ne    .Lnext
.Lcheck_hui:
    ldrb    w8, [x13, #6]
    cmp     w8, #0xe5
    b.ne    .Lnext
    ldrb    w8, [x13, #7]
    cmp     w8, #0x9b
    b.ne    .Lnext
    ldrb    w8, [x13, #8]
    cmp     w8, #0x9e
    b.eq    .Lself
    b       .Lnext
.Lenglish:
    cmp     x9, #12
    b.lo    .Lnext
    ldr     w8, [x13]
    mov     w9, #0x7559
    movk    w9, #0x206f, lsl #16
    cmp     w8, w9
    b.ne    .Lnext
    ldr     w8, [x13, #4]
    mov     w9, #0x6572
    movk    w9, #0x6163, lsl #16
    cmp     w8, w9
    b.ne    .Lnext
    ldr     w8, [x13, #8]
    mov     w9, #0x6c6c
    movk    w9, #0x6465, lsl #16
    cmp     w8, w9
    b.eq    .Lself
    b       .Lnext
.Lself:
    b       .Lresult
.Lnotself:
    str     xzr, [x19, #0x1c8]
.Lresult:
    eor     w19, w20, #1
    .long   0x17b74aac  // b 0x4667700 when loaded at 0x5894af8
