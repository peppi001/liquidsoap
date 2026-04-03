# Liquidsoap AppImage Docker Build Script

This repository provides a **fully automated build script** for creating a custom **Liquidsoap AppImage** using Docker.

The script encapsulates the entire build process inside a Docker container, so you can build a portable Liquidsoap binary on any Linux host without manually setting up dependencies.

---

## What This Script Does

The script performs the following steps:

1. **Builds a Docker image** based on Debian 12  
2. **Runs the build inside a container**, isolating all dependencies  
3. Compiles and bundles:
   - **OCaml 4.14 (via OPAM)**
   - **Liquidsoap 2.4.1**
   - **FFmpeg (with HTTP/HTTPS + OpenSSL + fdk-aac)**
   - **libfdk-aac and fdkaac CLI**
   - Required audio libraries (vorbis, lame, etc.)
4. Rebuilds `ocaml-ffmpeg` against the bundled FFmpeg  
5. Assembles a complete **AppDir**  
6. Uses **linuxdeploy** to generate an **AppImage**  
7. Outputs the final file on the host system  

---

## Output

The final AppImage is created in:

```
./Release/liquidsoap-WB.AppImage
```

---

## Requirements

- Linux host (tested on Debian 12)  
- Docker installed and working  
- x86_64 architecture  

---

## Usage

```
chmod +x liquidsoap-appimage-docker-build-release-wb.sh
./liquidsoap-appimage-docker-build-release-wb.sh
```
