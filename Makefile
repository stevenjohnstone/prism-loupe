.PHONY: all build serve clean

all: build

build:
	./scripts/build.sh

serve:
	@if [ ! -f dist/index.html ]; then ./scripts/build.sh; fi
	ruby -run -e httpd dist -p 8080

clean:
	rm -rf build dist
