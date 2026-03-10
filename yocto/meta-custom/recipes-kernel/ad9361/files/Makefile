ifneq ($(KERNELRELEASE),)
obj-m := ad9361.o
ad9361-y := ad9361_main.o ad9361_conv.o
else
default:
	$(MAKE) -C $(KERNEL_SRC) M=$(PWD) modules

modules_install:
	$(MAKE) -C $(KERNEL_SRC) M=$(PWD) modules_install

clean:
	$(MAKE) -C $(KERNEL_SRC) M=$(PWD) clean
endif
