# zjxl

Zig bindings for [libjxl](https://github.com/libjxl/libjxl) to load and save JPEG XL images.

Mostly a playground to learn how to use libjxl from Zig.

## Requirements

- A recent Zig nightly (see `minimum_zig_version` in `build.zig.zon`)
- libjxl installed on your system

## Building

```
zig build
```

## Usage

```
zig build run -- image.jxl [quality]
```

Loads `image.jxl` and saves it back as `output.jxl` with the given quality
(default: 100, which is lossless).

## License

MIT, see [LICENSE](LICENSE).
