use std::env;

fn main() {
    let default_root = format!(
        "{}/vendor/sherpa-onnx-v1.13.8-osx-arm64-shared",
        env!("CARGO_MANIFEST_DIR")
    );
    let root = env::var("SHERPA_ONNX_DIR").unwrap_or(default_root);
    let include = format!("{root}/include");
    let lib = format!("{root}/lib");

    cc::Build::new()
        .file("csrc/asr_shim.c")
        .include(&include)
        .warnings(true)
        .compile("ovc_asr_shim");

    println!("cargo:rustc-link-search=native={lib}");
    println!("cargo:rustc-link-lib=dylib=sherpa-onnx-c-api");
    println!("cargo:rustc-link-arg=-Wl,-rpath,{lib}");
    println!("cargo:rerun-if-changed=csrc/asr_shim.c");
    println!("cargo:rerun-if-env-changed=SHERPA_ONNX_DIR");
}
