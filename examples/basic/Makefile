.PHONY: all html jscoq-bin clean

PROJECT=Basic
BUILDDIR=build
SRC=src
SRCFILES=$(wildcard $(SRC)/*.v)
JSCOQDIR?=./node_modules/jscoq

all: html jscoq-bin
	mkdir -p $(BUILDDIR)/html/coq-pkgs
	cp $(BUILDDIR)/jscoq-bin/*.{coq-pkg,json} $(BUILDDIR)/html/coq-pkgs/

html: $(BUILDDIR) html-template/index.html
	mkdir -p $(BUILDDIR)/html
	cp html-template/index.html $(BUILDDIR)/html/
	cp -rT $(JSCOQDIR) $(BUILDDIR)/html/js

jscoq-bin: $(BUILDDIR) $(SRCFILES) $(SRC)/_CoqProject
	mkdir -p $(BUILDDIR)/jscoq-bin/src
# build the .v file using Coq-generated Makefile
	cp $(SRC)/*.v $(BUILDDIR)/jscoq-bin/src/
	cp $(SRC)/_CoqProject $(BUILDDIR)/jscoq-bin/src
	cd $(BUILDDIR)/jscoq-bin/src \
	&& coq_makefile -f _CoqProject *.v -o Makefile
	$(MAKE) -C $(BUILDDIR)/jscoq-bin/src
# the --top argument is necessary, because jsCoq does not read _CoqProject
	jscoq build --rootdir $(BUILDDIR)/jscoq-bin/src --package $(BUILDDIR)/jscoq-bin/$(PROJECT) --top $(PROJECT)

$(BUILDDIR):
	mkdir -p $(BUILDDIR)

clean:
	rm -rf $(BUILDDIR)
