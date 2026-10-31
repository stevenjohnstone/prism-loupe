.PHONY: all build serve clean

all: build

build:
	./scripts/build.sh

serve: build
	ruby -run -e httpd dist -p 8080

clean:
	rm -rf build dist
