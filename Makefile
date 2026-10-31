THEOS_PACKAGE_DIR_NAME = debs

PACKAGE_VERSION = $(THEOS_PACKAGE_BASE_VERSION)

DEBUG = 0

INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TheMoon

TheMoon_FILES = Tweak.xm
TheMoon_FRAMEWORKS = UIKit CoreGraphics
TARGET = iphone:clang:16.5:9.0
TheMoon_CFLAGS = -fobjc-arc
TheMoon_CCFLAGS = -std=c++14 -stdlib=libc++ -fno-rtti -fno-exceptions

ARCHS = arm64

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS)/makefiles/aggregate.mk

after-install::
	install.exec "killall -9 '-'"