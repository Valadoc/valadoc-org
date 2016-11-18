VALAC = valac
VALAC_VERSION := $(shell vala --version | awk -F. '{ print "0."$$2 }')
VALAFLAGS = -X -w
PREFIX = "stable"

gee-version = 0.18.1
gee-pc-version = 0.8


default: app generator libdoclet.so update-girs configgen valadoc-example-gen valadoc-example-tester

datadir := $(shell dirname $(CURDIR)/$(word $(words $(MAKEFILE_LIST)),$(MAKEFILE_LIST)))


clean:
	$(RM) documentation/*/wiki/example-listing.valadoc
	$(RM) documentation/*/wiki/example-listing-*.valadoc
	$(RM) documentation/*/wiki/widget-gallery.valadoc
	$(RM) documentation/*/wiki/devhelp-index.valadoc
	$(RM) documentation/*/wiki/index.valadoc
	$(RM) -r documentation/*/gallery-images
	$(RM) -r documentation/*/gir-images
	$(RM) examples/*-examples.valadoc
	$(RM) -r sphinx/storage
	$(RM) valadoc-example-tester
	$(RM) valadoc-example-gen
	$(RM) configgen
	$(RM) generator
	$(RM) app
	$(RM) -r extra-vapis
	$(RM) -r girs
	$(RM) -r tmp
	$(RM) *.so
	$(RM) LOG


app: src/valadoc-app.vala
	$(VALAC) -o $@ $< --pkg=valum-0.3 --pkg=libgda-5.0


valadoc-example-gen: src/valadoc-example-parser.vala src/valadoc-example-gen.vala
	$(VALAC) $(VALAFLAGS) -o $@ $^

valadoc-example-tester: src/valadoc-example-parser.vala src/valadoc-example-tester.vala
	$(VALAC) $(VALAFLAGS) -o $@ $^


DOCLET_DEPS = gee-0.8 valadoc-1.0
DOCLET_VALAFLAGS := $(patsubst %,--pkg=%,$(DOCLET_DEPS))
DOCLET_CFLAGS := $(shell pkg-config --cflags --libs $(DOCLET_DEPS)) -shared -fPIC -w

libdoclet.so: src/doclet.vala src/linkhelper.vala
	$(VALAC) $(VALAFLAGS) $(DOCLET_VALAFLAGS) -C $^
	$(CC) $(DOCLET_CFLAGS) -o $@ $(patsubst %.vala,%.c,$^)
	$(RM) $(patsubst %.vala,%.c,$^)


GENERATOR_DEPS = gee-0.8 valadoc-1.0 gio-2.0
GENERATOR_VALAFLAGS := $(patsubst %,--pkg=%,$(GENERATOR_DEPS)) --enable-experimental

generator: src/doclet.vala src/linkhelper.vala src/generator.vala
	$(VALAC) $(VALAFLAGS) $(GENERATOR_VALAFLAGS) -o $@ $^


configgen: src/configgen.vala
	$(VALAC) $(VALAFLAGS) -o $@ $^ -X -D -X datadir=\"$(datadir)\" --vapidir src/ --pkg config --enable-experimental


update-girs:
	[ -d girs ]        && git -C girs pull        || git clone https://github.com/nemequ/vala-girs.git girs 
	[ -d extra-vapis ] && git -C extra-vapis pull || git clone https://github.com/nemequ/vala-extra-vapis.git extra-vapis 


#
# Example checks:
#

check-examples: valadoc-example-tester
	./valadoc-example-tester --keep-running --force \
                         examples/cairo/cairo.valadoc.examples \
                         examples/gio-2.0/gio-2.0.valadoc.examples \
                         examples/glib-2.0/glib-2.0.valadoc.examples \
                         examples/gmodule-2.0/gmodule-2.0.valadoc.examples \
                         examples/gmodule-2.0/gmodule-2.0.valadoc.examples \
                         examples/gobject-2.0/gobject-2.0.valadoc.examples \
                         examples/gstreamer-1.0/gstreamer-1.0.valadoc.examples \
                         examples/gstreamer-video-1.0/gstreamer-video-1.0.valadoc.examples \
                         examples/gtk+-3.0/gtk+-3.0.valadoc.examples \
                         examples/json-glib-1.0/json-glib-1.0.valadoc.examples \
                         examples/libnotify/libnotify.valadoc.examples \
                         examples/libsoup-2.4/libsoup-2.4.valadoc.examples \
                         examples/libxml-2.0/libxml-2.0.valadoc.examples \
                         examples/rest-0.7/rest-0.7.valadoc.examples \
                         examples/sqlite3/sqlite3.valadoc.examples



#
# Documentation generation:
#


build-docs: generator libdoclet.so
	$(RM) -r tmp/
	./generator \
        --vapidir /usr/share/vala-$(VALAC_VERSION)/vapi/ \
        --vapidir "extra-vapis/" --vapidir "girs/vala/vapi/" \
        --driver $(VALAC_VERSION) \
        --prefix $(PREFIX) \
        --target-glib 2.99 \
        --download-images \
        --skip-existing \
        --no-check-certificate \
        --all
	if ! test -d valadoc.org/gee-$(gee-pc-version); then \
		wget https://git.gnome.org/browse/libgee/snapshot/libgee-$(gee-version).zip ; \
		unzip libgee-$(gee-version).zip ; \
		valadoc -o libgee-$(gee-version)/gee-$(gee-pc-version) --target-glib=2.99 --pkg gio-2.0 libgee-$(gee-version)/gee/*.vala libgee-$(gee-version)/utils/geeutils.vapi --wiki libgee-$(gee-version)/doc/ --doclet . ; \
		mv libgee-$(gee-version)/gee-$(gee-pc-version)/gee-$(gee-pc-version) valadoc.org/ ; \
		rm -r libgee-$(gee-version) libgee-$(gee-version).zip ; \
	fi


build-docs-mini: generator libdoclet.so
	$(RM) -r tmp/
	./generator \
        --vapidir /usr/share/vala-$(VALAC_VERSION)/vapi/ \
        --vapidir "extra-vapis/" --vapidir "girs/vala/vapi/" \
        --driver $(VALAC_VERSION) \
        --prefix $(PREFIX) \
        --target-glib 2.99 \
        --download-images \
        --skip-existing \
        --no-check-certificate \
        --disable-devhelp \
        "glib-2.0" "gio-2.0" "gobject-2.0"


test-examples: valadoc-example-tester
	-./valadoc-example-tester examples/*/*.valadoc.examples
	$(RM) -r tmp/

#
# Run a local webserver serving valadoc.org
#

serve: default build-docs
	FWD_SEARCH=1 FWD_TOOLTIP=1 ./app
serve-mini: default build-docs-mini
	FWD_SEARCH=1 FWD_TOOLTIP=1 ./app
