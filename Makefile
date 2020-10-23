VALAC ?= valac
PACKAGES ?= --all
GENERATOR_OPTS ?= --disable-devhelp --skip-existing
VALAC_VERSION := $(shell $(VALAC) --api-version | awk -F. '{ print "0."$$2 }')
VAPIDIRS := --vapidir $(shell pkg-config --variable vapidir libvala-$(VALAC_VERSION)) --vapidir $(shell pkg-config --variable vapidir valadoc-$(VALAC_VERSION))
VALAFLAGS = -g -X -w $(VAPIDIRS)
PREFIX = "stable"

default: generator libdoclet.so update-girs configgen valadoc-example-gen valadoc-example-tester

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
	$(RM) -r extra-vapis
	$(RM) -r girs
	$(RM) -r tmp
	$(RM) *.so
	$(RM) LOG


valadoc-example-gen: src/valadoc-example-parser.vala src/valadoc-example-gen.vala
	$(VALAC) $(VALAFLAGS) -o $@ $^

valadoc-example-tester: src/valadoc-example-parser.vala src/valadoc-example-tester.vala
	$(VALAC) $(VALAFLAGS) -o $@ $^


DOCLET_DEPS = gee-0.8 valadoc-$(VALAC_VERSION)
DOCLET_VALAFLAGS := $(patsubst %,--pkg=%,$(DOCLET_DEPS))
DOCLET_CFLAGS := $(shell pkg-config --cflags --libs $(DOCLET_DEPS)) -shared -fPIC -w

libdoclet.so: src/doclet.vala src/linkhelper.vala
	$(VALAC) $(VALAFLAGS) $(DOCLET_VALAFLAGS) -C $^
	$(CC) $(DOCLET_CFLAGS) -o $@ $(patsubst %.vala,%.c,$^)
	$(RM) $(patsubst %.vala,%.c,$^)


GENERATOR_DEPS = gee-0.8 valadoc-$(VALAC_VERSION) gio-2.0
GENERATOR_VALAFLAGS := $(patsubst %,--pkg=%,$(GENERATOR_DEPS)) --enable-experimental

generator: src/doclet.vala src/linkhelper.vala src/generator.vala
	$(VALAC) $(VALAFLAGS) $(GENERATOR_VALAFLAGS) -o $@ $^


configgen: src/configgen.vala
	$(VALAC) $(VALAFLAGS) -o $@ $^ -X -D -X datadir=\"$(datadir)\" --vapidir src/ --pkg config --enable-experimental


update-girs:
	[ -d girs ]        && git -C girs pull        || git clone https://github.com/nemequ/vala-girs.git girs --depth 1
	[ -d extra-vapis ] && git -C extra-vapis pull || git clone https://gitlab.gnome.org/GNOME/vala-extra-vapis.git extra-vapis --depth 1


#
# Example checks:
#

check-examples: valadoc-example-tester
	./valadoc-example-tester --keep-running --force \
		examples/cairo/cairo.valadoc.examples \
		examples/gee-0.8/gee-0.8.valadoc.examples \
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
# Build local assets
#

build-data:
	npx gulp

#
# Documentation generation:
#


build-docs: default
	$(RM) -r tmp/
	./generator \
		--vapidir "extra-vapis/" --vapidir "girs/vala/vapi/" \
		--prefix $(PREFIX) \
		--target-glib 2.98 \
		--download-images \
		--no-check-certificate \
		$(GENERATOR_OPTS) \
		$(PACKAGES)

build-docs-mini: default
	make build-docs PACKAGES="glib-2.0 gio-2.0 gobject-2.0"

test-examples: valadoc-example-tester
	$(RM) -r tmp/
	-./valadoc-example-tester examples/*/*.valadoc.examples && $(RM) -r tmp/


#
# Run a local webserver serving valadoc.org
#


serve: build-docs build-data
	FWD_SEARCH=1 FWD_TOOLTIP=1 php -S localhost:7777 -t ./valadoc.org $(PWD)/valadoc.org/router.php

serve-mini: build-docs-mini build-data
	FWD_SEARCH=1 FWD_TOOLTIP=1 php -S localhost:7777 -t ./valadoc.org $(PWD)/valadoc.org/router.php

serve-search: configgen
	./configgen ./valadoc.org/
	mkdir ./sphinx/storage
	indexer --config ./sphinx.conf --all
	searchd --config sphinx.conf
