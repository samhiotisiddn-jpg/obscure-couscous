.PHONY: install dev build clean

install:
	pnpm install

dev:
	pnpm dev

build:
	pnpm build

clean:
	rm -rf node_modules dist
