# FCAdBlock —— 丰巢去广告插件（独立插件，运行时不依赖其它 tweak）
# 编译：make package          生成 .deb
# 巨魔注入用 .theos/obj/FCAdBlock.dylib
ARCHS = arm64
TARGET := iphone:clang:latest:13.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = FCAdBlock

# 全部是普通 Objective-C：不使用 Logos / CydiaSubstrate
FCAdBlock_FILES = $(wildcard src/*.m)
FCAdBlock_FRAMEWORKS = UIKit Foundation
FCAdBlock_CFLAGS = -fobjc-arc \
                   -Wno-deprecated-declarations -Wno-unused-variable \
                   -Wno-unused-function -Wno-unused-const-variable \
                   -DFC_SHOW_BADGE=1
FCAdBlock_LDFLAGS = -Wl,-undefined,dynamic_lookup

# 实验对照版：FC_VARIANT=deep 时额外 swizzle 宿主自有广告类，仍不碰任何系统类
ifeq ($(FC_VARIANT),deep)
FCAdBlock_CFLAGS += -DFC_DEEP_HOOKS=1
endif

include $(THEOS_MAKE_PATH)/tweak.mk
