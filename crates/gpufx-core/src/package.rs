//! Effect packages: a zip (or, for development, a directory) holding `manifest.json`,
//! WGSL shaders and optional PNG textures.

use std::collections::HashMap;
use std::io::Read;
use std::path::Path;

use crate::manifest::Manifest;
use crate::Error;

/// Hard limits so a hostile package cannot exhaust memory.
const MAX_FILES: usize = 1024;
const MAX_TOTAL_BYTES: u64 = 256 << 20;

#[derive(Debug, Clone)]
pub struct Package {
    pub manifest: Manifest,
    files: HashMap<String, Vec<u8>>,
}

impl Package {
    /// Opens a `.zip` package or an unpacked package directory.
    pub fn open(path: impl AsRef<Path>) -> Result<Self, Error> {
        let path = path.as_ref();
        let files = if path.is_dir() { read_dir(path)? } else { read_zip(&std::fs::read(path)?)? };
        Self::from_files(files)
    }

    /// Loads a package from zip bytes held in memory.
    pub fn from_zip_bytes(bytes: &[u8]) -> Result<Self, Error> {
        Self::from_files(read_zip(bytes)?)
    }

    fn from_files(files: HashMap<String, Vec<u8>>) -> Result<Self, Error> {
        let manifest_bytes = files.get("manifest.json").ok_or_else(|| Error::Package("missing manifest.json".into()))?;
        let manifest = Manifest::parse(manifest_bytes)?;
        let pkg = Package { manifest, files };
        for pass in &pkg.manifest.passes {
            pkg.file(&pass.shader)?;
        }
        for tex in &pkg.manifest.textures {
            for f in tex.files() {
                pkg.file(f)?;
            }
        }
        // Image sizes come from the headers: nothing is decoded until a device loads it.
        crate::texture::check_package(&pkg)?;
        Ok(pkg)
    }

    pub fn file(&self, path: &str) -> Result<&[u8], Error> {
        self.files
            .get(normalize(path).as_str())
            .map(Vec::as_slice)
            .ok_or_else(|| Error::Package(format!("missing file `{path}` in package")))
    }

    pub fn text(&self, path: &str) -> Result<&str, Error> {
        std::str::from_utf8(self.file(path)?).map_err(|_| Error::Package(format!("`{path}` is not UTF-8")))
    }
}

fn normalize(path: &str) -> String {
    path.replace('\\', "/").trim_start_matches("./").to_string()
}

fn read_zip(bytes: &[u8]) -> Result<HashMap<String, Vec<u8>>, Error> {
    let mut zip = zip::ZipArchive::new(std::io::Cursor::new(bytes)).map_err(|e| Error::Package(e.to_string()))?;
    if zip.len() > MAX_FILES {
        return Err(Error::Package("too many files in package".into()));
    }
    let mut files = HashMap::new();
    let mut total = 0u64;
    for i in 0..zip.len() {
        let mut entry = zip.by_index(i).map_err(|e| Error::Package(e.to_string()))?;
        if entry.is_dir() {
            continue;
        }
        // `enclosed_name` rejects absolute paths and `..` components.
        let name =
            entry.enclosed_name().ok_or_else(|| Error::Package(format!("unsafe path `{}`", String::from_utf8_lossy(entry.name_raw()))))?;
        let name = normalize(&name.to_string_lossy());
        let mut data = Vec::new();
        let budget = MAX_TOTAL_BYTES - total;
        (&mut entry).take(budget + 1).read_to_end(&mut data)?;
        total += data.len() as u64;
        if total > MAX_TOTAL_BYTES {
            return Err(Error::Package("package is too large".into()));
        }
        files.insert(name, data);
    }
    Ok(files)
}

fn read_dir(root: &Path) -> Result<HashMap<String, Vec<u8>>, Error> {
    let mut files = HashMap::new();
    let mut stack = vec![root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        for entry in std::fs::read_dir(&dir)? {
            let path = entry?.path();
            if path.is_dir() {
                stack.push(path);
            } else {
                let rel = path.strip_prefix(root).expect("walked from root");
                files.insert(normalize(&rel.to_string_lossy()), std::fs::read(&path)?);
                if files.len() > MAX_FILES {
                    return Err(Error::Package("too many files in package".into()));
                }
            }
        }
    }
    Ok(files)
}

impl Package {
    /// Zips the package directory `dir` into `out`, after checking it opens. With
    /// `precompile`, the D3D12 shaders of its passes are added under `compiled/dx12/` (see
    /// [`crate::precompile`]); a `compiled/` folder already in `dir` is never copied.
    /// Returns the number of shaders added.
    pub fn pack(dir: &Path, out: &Path, precompile: bool) -> Result<usize, Error> {
        let pkg = Package::open(dir)?;
        let compiled = if precompile { crate::precompile(&pkg)? } else { Vec::new() };
        let mut files = Vec::new();
        let mut stack = vec![dir.to_path_buf()];
        while let Some(d) = stack.pop() {
            for entry in std::fs::read_dir(&d)? {
                let path = entry?.path();
                if path.is_dir() {
                    // Stale blobs of another version must not ship.
                    if path != dir.join("compiled") {
                        stack.push(path);
                    }
                } else {
                    files.push(path);
                }
            }
        }
        files.sort();
        let zip_err = |e: zip::result::ZipError| Error::Package(e.to_string());
        let mut zip = zip::ZipWriter::new(std::fs::File::create(out)?);
        let opts = zip::write::SimpleFileOptions::default().compression_method(zip::CompressionMethod::Deflated);
        for path in files {
            let rel = normalize(&path.strip_prefix(dir).expect("walked from dir").to_string_lossy());
            zip.start_file(rel, opts).map_err(zip_err)?;
            std::io::Write::write_all(&mut zip, &std::fs::read(&path)?)?;
        }
        for (name, data) in &compiled {
            // DXIL is already compressed.
            zip.start_file(name.as_str(), opts.compression_method(zip::CompressionMethod::Stored)).map_err(zip_err)?;
            std::io::Write::write_all(&mut zip, data)?;
        }
        zip.finish().map_err(zip_err)?;
        Ok(compiled.len())
    }
}
