# 00 Before you start

You have read a C function and called it from Rust in [Core 05](../../../05-rust-for-systems/README.md). Here you write the library, own its memory discipline, and link in both directions. Use Linux with a C17-capable GCC or Clang and its ASan and UBSan runtimes, GNU Make, `ar`, Rust 1.89+ with Rustfmt and Clippy, and Python 3. Use the same C compiler for Make and Cargo. If you set `CC` or `AR`, use the executable name or its path.

Record the Blueprint checkout path, then create a fresh working directory outside the checkout.

~~~bash
export blueprint=$(pwd)
mkdir -p ~/byte-bridge-lab
cd ~/byte-bridge-lab
cc --version
make --version
cargo --version
~~~

Create directories as you add files. Type each completed step before running its check. The library builds offline with the system toolchain and Rust standard library.
<!-- file: .gitignore -->
~~~text
/build/
/target/
~~~
