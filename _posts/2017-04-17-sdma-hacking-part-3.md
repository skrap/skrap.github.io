---
title:  "SDMA Hacking Part 3: Script Parameters"
tags: code sdma
---
# {{ page.title }}

The script we wrote in Part 2 was cute, but not particularly useful.  What's a DMA engine if it can't copy data around your system for you?  Fortunately, the SDMA comes with a bunch of useful scripts in its ROM section, and most SoCs have a companion firmware file which contains further scripts to be loaded into the SDMA's RAM section, and run.

> This appendix provides descriptions of scripts that may be used
> to perform data transfers using the Smart DMA (SDMA) block of 
> the SoC. The SDMA block supports data transfer from core memory
> space to core memory, from core memory space to peripherals, and 
> vice versa.
>
> -- i.MX53 Reference Manual, Appendix A

SDMA ROM scripts follow a roughly standard convention for the CPU follow in order to pass parameters to the script.  There are two ways for a script to receive parameters:

- passed in registers, via its channel context
- passed via buffer descriptors

Passing parameters via registers should be familiar enough to most engineers, so I won't cover it here.  However, "channel context" and "buffer descriptors" deserve a bit more attention.

## Buffer Descriptors

Certain script parameters are passed via a buffer descriptor.

A buffer descriptor specifies one unit of work for the SDMA engine, and indicates what should happen afterwards.  In plain English, a buffer descriptor might say "Copy 1024 bytes from the SPI module's RX FIFO, then signal the CPU and stop."  Buffer descriptors can be chained together, and optionally looped, to create cyclic or scatter-gather functionality.

It's up to the CPU to set up an array of buffer descriptors in **ARM platform memory** (not in the SDMA RAM).  The SDMA script will copy the active buffer descriptor into SDMA RAM when it begins a new buffer, but the master copy of a buffer descriptor will always live in the system memory (OCRAM or DRAM).

A full specification of the buffer descriptor format can be found in the reference manual for your processor.  For example, the i.MX7 has section 55.7.1.1 "Buffer Descriptor Format".  I won't reproduce the whole thing here.  If you want to know about them, read "Buffer Descriptor Field Descriptions" in your reference manual.

```c
struct sdma_mode_count {
	u32 count   : 16; /* size of the buffer pointed by this BD */
	u32 status  :  8; /* E,R,I,C,W,D status bits stored here */
	u32 command :  8; /* command mostlky used for channel 0 */
};

struct sdma_buffer_descriptor {
	struct sdma_mode_count  mode;
	u32 buffer_addr;	/* address of the buffer described */
	u32 ext_buffer_addr;	/* extended buffer address */
} __attribute__ ((packed));
```


## Channel Control Blocks

In order to use buffer descriptors, you need to set up a channel control block.  This is a structure which points to the current buffer descriptor, and also to the first buffer descriptor for a channel.  (The first BD pointer is used when the last buffer descriptor is marked to wrap back to the first.)

```c
struct sdma_channel_control {
	u32 current_bd_ptr;
	u32 base_bd_ptr;
	u32 unused[2];
} __attribute__ ((packed));
```

They are allocated by the CPU-side driver, and kept in AP memory space, like the buffer descriptors.  There is one memory-mapped SDMA register which points to the beginning of this array: Also like the buffer descriptors, the SDMA script is responsible for copying the control block for its channel from AP memory into SDMA memory.

## Channel Contexts

Besides Buffer Descriptors, the other way to pass parameters to a channel's script is to write to its registers via its channel context.

The SDMA processor can switch between channels, and when it does, it preserves the channel's state into a channel context in **SDMA internal RAM**.  This context contains all of the register state, as well as the state of the SDMA peripherals, and also some per-channel scratch space.  The full structure can be found in the "Context Switching-Programming" section of your reference manual.

However, what you really need to know about these things is that when you are setting a script up to run, you create a channel context in your CPU-side driver, and set various registers:
* Set the PC register to your script's address in RAM
* Set other registers as needed as well

## Linux Walkthrough

It seems worthwhile to me to quickly look at how this works in practice, as the Linux SDMA driver sets up a channel, its buffer descriptors, control block, and channel context.  You can see all these steps in action in Linux's imx-sdma.c:

1. allocate channel control blocks for all channels in `sdma_init()`
1. tells the SDMA about the channel control blocks by setting `SDMA_H_C0PTR`.
1. allocate one channel context to be used as a template for setting up channels as needed.
1. allocating and configuring a channel's buffer descriptors in the `sdma_prep_*` functions, e.g. `sdma_prep_sg()`.
    * after the buffer descriptors are set up, the channel's control block is pointed at the first and current buffer descriptor.
1. configuring the template channel context with the correct script address and parameters, in `sdma_load_context()`
    * note that this function uses the channel0 `SETDM` script to copy the context to its position in SDMA RAM
1. finally, the channel's start bit is written, in `sdma_enable_channel()`, and the channel becomes available for running on the SDMA processor!

## Standard Script Paramaters

So what *are* those parameters we were talking about?  Well, the parameters in question are typically the following:
* r1 "Events" and r0 "Events2", see "Event_mask and Event2_mask"
* r6 "FIFO Address" is used for scripts targeting a peripheral, e.g. ECSPI.
* r7 "Watermark Level" is how many transfers the script should do before waiting for another DMA event.
    *  *It is vital that this match with however you've configured the peripheral!*  Each peripheral has a DMA TX/RX watermark, and it really should match the value passed to the SDMA script.  Unless you want bugs or lousy performance, I guess!

See Appendix A of the i.MX6DQ Reference Manual, in the section named "Parameters Definition", for more details.

Whew! That's a lot to chew on.  When you're ready, meet me in [Part 4!](sdma-hacking-part-4.html).
