use std::path::{Path, PathBuf};

fn main() {
    openmpt();
}

fn openmpt() {
    println!("cargo:rerun-if-env-changed=OPENMPT_SOURCE");
    let root = std::env::var_os("OPENMPT_SOURCE")
        .map(PathBuf::from)
        .unwrap_or_else(|| Path::new(env!("CARGO_MANIFEST_DIR")).join("../.build/libopenmpt"));
    let makefile = root.join("build/android_ndk/Android.mk");
    println!("cargo:rerun-if-changed={}", root.join(".version").display());
    let Ok(list) = std::fs::read_to_string(&makefile) else {
        panic!("libopenmpt source not found at {}: run `just build plugins` or set OPENMPT_SOURCE", root.display());
    };
    let sources = list.lines().map(|line| line.trim().trim_end_matches('\\').trim()).filter(|line| line.ends_with(".cpp"));
    let defines = [
        ("LIBOPENMPT_BUILD", None),
        ("MPT_WITH_MINIZ", None),
        ("MPT_WITH_MINIMP3", None),
        ("MPT_WITH_STBVORBIS", None),
        ("STB_VORBIS_NO_PULLDATA_API", None),
        ("STB_VORBIS_NO_STDIO", None),
    ];
    let mut cpp = cc::Build::new();
    cpp.cpp(true).std("c++17").warnings(false).flag_if_supported("-fvisibility=hidden");
    let mut c = cc::Build::new();
    c.warnings(false).flag_if_supported("-fvisibility=hidden");
    for build in [&mut cpp, &mut c] {
        build.include(&root).include(root.join("src")).include(root.join("common")).include(root.join("include")).opt_level(2);
        for (name, value) in defines {
            build.define(name, value);
        }
    }
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("windows")
        && std::env::var("CARGO_CFG_TARGET_ENV").as_deref() == Ok("gnu")
    {
        cpp.cpp_link_stdlib(None);
        let output = cpp.get_compiler().to_command().arg("-print-file-name=libstdc++.a").output().expect("the C++ compiler can't be run");
        let archive = PathBuf::from(String::from_utf8_lossy(&output.stdout).trim());
        println!("cargo:rustc-link-search=native={}", archive.parent().unwrap().display());
        println!("cargo:rustc-link-lib=static=stdc++");
    }
    cpp.files(sources.map(|source| root.join(source))).compile("openmpt");
    c.files(["miniz/miniz.c", "minimp3/minimp3.c", "stb_vorbis/stb_vorbis.c"].map(|source| root.join("include").join(source)))
        .compile("openmpt_deps");
}
