---
title:  "SDMA Hacking Part I: Introduction"
tags: code sdma
---
This is the first in a series of posts on working with the SDMA engine on NXP's i.MX series processors.  The SDMA engine is a simple RISC processor masquerading as a DMA engine, and it is used to perform DMA tasks on the i.MX SoC.

Here's what's in the series:
* Part 1: Introduction (this part)
* [Part 2: Creating Custom Scripts](/sdma-hacking/part-2.html)
* [Part 3: Script Parameters](/sdma-hacking/part-3.html)
* [Part 4: Standard ROM Scripts](/sdma-hacking/part-4.html)
* [Part 5: Custom SPI Script](/sdma-hacking/part-5.html)


The SDMA engine is a processor in its own right, and it is fully programmable.  Its programs are called "scripts", even though they are really compiled to bytecode, and don't resemble anything human-readable in their raw form.  This is somewhat exciting, as it means that we can use the SDMA processor to push the i.MX harder than linux alone could.

First off, I need to call out Eli Billauer's excellent series of blog posts on the SDMA engine.  If you are wondering how to work with SDMA, you will get a great overview.
- [Part I: Introduction, addressing and the memory map](http://billauer.co.il/blog/2011/10/imx-sdma-howto-memory-map/){:target="_blank"}
- [Part II: Contexts, Channels, Scripts and their execution](http://billauer.co.il/blog/2011/10/imx-sdma-howto-channels-scripts/){:target="_blank"}
- [Part III: Events and Interrupts](http://billauer.co.il/blog/2011/10/imx-sdma-howto-events-interrupts/){:target="_blank"}
- [Part IV: Running custom SDMA scripts in Linux](http://billauer.co.il/blog/2011/10/imx-sdma-howto-assembler-linux/){:target="_blank"}
- Bonus: [Examples of SDMA-assembler for Freescale i.MX51](http://billauer.co.il/blog/2011/11/imx-sdma-assembler-example/){:target="_blank"}, which builds some working examples.

My intention here is not to duplicate Eli's work, but rather update and extend it.  The SDMA engine has remained an important part of NXP's SoCs to this day, and it's included with the i.MX6 and i.MX7 series processors.  From what I can tell, the actual chip is probably identical.  However, NXP's documentation for this module is quite sparse, so I wanted to collect and publish what I have learned.

# The MX6/MX7 Knowledge Hole

Eli's work brought us a good understanding of the i.MX51's SDMA engine.  All signs that I've come across are that the SDMA in today's i.MX6 and i.MX7 is basically the same as it was through the whole line, possibly back as far as the i.MX25.  However, for some reason, each successive generation of documentation omitted more and more of the SDMA information.  Someone starting today on the i.MX7 would not find nearly enough usable info make much headway using the SDMA at all.

So, here's some pointers:

Generally, the [i.MX51 Reference Manual](http://www.nxp.com/assets/documents/data/en/reference-manuals/MCIMX51RM.pdf) will be good documentation for the SDMA core itself, including the **last** published details for SDMA Internal Registers Memory Map in section 52.14.1.

The i.MX51 manual doesn't include documentation on the SDMA scripts themselves.  For that, you should check the [i.MX6DQ Reference Manual](http://cache.freescale.com/files/32bit/doc/ref_manual/IMX6DQRM.pdf), which is the most up-to-date listing of the ROM and RAM scripts available, in Appendix A.  This is notable as it is the only place which actually describes the passing of parameters from the ARM Core to the SDMA, which varies depending on which script you're calling.

# Our Mission

When Part IV of Eli's SDMA blog concluded, he had demonstrated how to assemble and run very simple SDMA scripts.  I want to take this further, and write a more complex script which makes full use of the SDMA.  To this end, my goal will be to write a specialized script for use with the i.MX7 SPI peripheral, which requires data to be written to the transmit FIFO in order to receive.   My script will write zeroes to the peripheral over the shared peripheral bus, and read back the received transmissions from the SPI slave, writing them to main memory.  The script will be written to be compatible with the 4.1.15 Linux SDMA driver, which is somewhat changed since Eli looked at it in 2011.

This example may seem a bit esoteric, but regular sampling from simple SPI ADCs is actually a very common use case.  And if you understand this example, it can serve as a launching point for nearly any other type of script one might want to write!

We'll continue in [Part 2: Creating Custom Scripts](/sdma-hacking/part-2.html)...

