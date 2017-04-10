---
title:  "SDMA Hacking Part 3: Script Parameters"
tags: code sdma
---
# {{ page.title }}

The script we wrote in Part 2 was cute, but not particularly useful.  What's a DMA engine if it can't copy data around your system for you?  Fortunately, we can do a lot of useful stuff with these scripts.  The SDMA comes with a bunch of useful scripts in its ROM section, and most SoCs have a firmware file which contains further scripts to be loaded into the SDMA's RAM section, and run.

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

## Channel Context Blocks

## Channel Contexts

## Standard Script Paramaters
