import os
import io
import zipfile
import urllib.request
import ssl

# Fix for macOS SSL Error
ssl._create_default_https_context = ssl._create_unverified_context

DATA_DIR = "./data"

DOC_SOURCES = {
    "Vite": {
        "url": "https://codeload.github.com/vitejs/vite/zip/refs/heads/main",
        "target_folder": "data/vite",
        "filter_prefix": "vite-main/docs/"
    },
    "Storybook": {
        "url": "https://codeload.github.com/storybookjs/storybook/zip/refs/heads/next",
        "target_folder": "data/storybook",
        "filter_prefix": "storybook-next/docs/"
    },
    "MDN_Web_Docs": {
        "url": "https://codeload.github.com/mdn/content/zip/refs/heads/main",
        "target_folder": "data/mdn",
        "filter_prefixes": [
            "content-main/files/en-us/web/javascript/",
            "content-main/files/en-us/web/css/",
            "content-main/files/en-us/web/html/",
            "content-main/files/en-us/web/api/"
        ]
    }
}

def download_and_extract(name, config):
    target = config["target_folder"]
    
    # --- NEW CHECK: Skip if already downloaded ---
    if os.path.exists(target) and os.listdir(target):
        print(f"⏭️  {name} docs already exist in {target}. Skipping download.")
        return
    # ---------------------------------------------
        
    print(f"\n📦 Downloading official docs for {name}...")
    req = urllib.request.Request(config["url"], headers={"User-Agent": "Mozilla/5.0"})
    
    try:
        with urllib.request.urlopen(req) as response:
            zip_data = response.read()
        
        print(f"⚡ Extracting {name} documentation to {target}...")
        with zipfile.ZipFile(io.BytesIO(zip_data)) as z:
            count = 0
            for file_info in z.infolist():
                if file_info.is_dir():
                    continue
                
                is_target = False
                if "filter_prefixes" in config:
                    is_target = any(file_info.filename.startswith(p) for p in config["filter_prefixes"])
                elif "filter_prefix" in config:
                    is_target = file_info.filename.startswith(config["filter_prefix"])

                if is_target and file_info.filename.endswith(('.md', '.mdx')):
                    relative_path = os.path.basename(file_info.filename)
                    out_path = os.path.join(target, relative_path)
                    
                    os.makedirs(os.path.dirname(out_path), exist_ok=True)
                    with z.open(file_info) as source, open(out_path, "wb") as target_file:
                        target_file.write(source.read())
                    count += 1
            print(f"✅ Saved {count} documentation files for {name}.")
    except Exception as e:
        print(f"❌ Failed to fetch {name}: {e}")

if __name__ == "__main__":
    os.makedirs(DATA_DIR, exist_ok=True)
    print("🚀 Starting documentation download script...")
    for name, config in DOC_SOURCES.items():
        download_and_extract(name, config)
    print("\n🎉 All docs checked/downloaded! You can now run 'python ingest.py'.")