import os
import io
import zipfile
import urllib.request
import urllib.error
import ssl

# Fix for macOS SSL Handshake errors
ssl._create_default_https_context = ssl._create_unverified_context

DATA_DIR = "./data"
MEMORIES_DIR = "./memories"

# Branch candidates to try if main fails
BRANCH_CANDIDATES = ["main", "master", "trunk", "development", "next", "v2"]

DOC_SOURCES = {
    # --- 1. NNg & UX Heuristics / Articles ---
    "Laws_of_UX": {
        "repo": "keysjoao/laws-of-ux-skills",
        "target_folder": "data/ux_heuristics",
        "subpath": ""
    },
    "UX_Craft_and_Principles": {
        "repo": "nexu-io/open-design",
        "target_folder": "data/ux_heuristics",
        "subpath": "craft/"
    },

    # --- 2. Public UX & Programming Books ---
    "Free_Programming_Books": {
        "repo": "EbookFoundation/free-programming-books",
        "target_folder": "data/books_programming",
        "subpath": "books/"
    },
    "Design_Books_Catalog": {
        "repo": "robleto/design-books",
        "target_folder": "data/books_ux",
        "subpath": ""
    },
    "Atomic_Design_Book": {
        "repo": "bradfrost/atomic-design",
        "target_folder": "data/graphic_design",
        "subpath": ""
    },
    "Awesome_Design_Systems": {
        "repo": "alialaa/awesome-design-systems",
        "target_folder": "data/graphic_design",
        "subpath": ""
    },

    # --- 3. Figma & Miro Developer Platform Docs ---
    "Figma_Plugin_Docs": {
        "repo": "figma/plugin-docs",
        "target_folder": "data/figma_docs",
        "subpath": ""
    },
    "Figma_Community_Resources": {
        "repo": "figma/community-resources",
        "target_folder": "data/figma_docs",
        "subpath": ""
    },
    "Miro_Developer_Examples": {
        "repo": "miroapp/app-examples",
        "target_folder": "data/miro_docs",
        "subpath": ""
    },

    # --- 4. Machine Learning ---
    "Scikit_Learn_ML": {
        "repo": "scikit-learn/scikit-learn",
        "target_folder": "data/machine_learning",
        "subpath": "doc/modules/"
    },
    "FastAI_Deep_Learning_Book": {
        "repo": "fastai/fastbook",
        "target_folder": "data/machine_learning",
        "subpath": ""
    },
    "PyTorch_Tutorials": {
        "repo": "pytorch/tutorials",
        "target_folder": "data/machine_learning",
        "subpath": "beginner_source/"
    },

    # --- 5. UX Design Materials (PUCRS / General) ---
    "UX_Best_Practices": {
        "repo": "mendix/docs",
        "target_folder": "data/pucrs_ux",
        "subpath": "content/en/docs/howto/front-end/"
    },

    # --- 6. Web Components (HTML, CSS, JavaScript) ---
    "MDN_Web_Docs": {
        "repo": "mdn/content",
        "target_folder": "data/mdn_web_docs",
        "subpaths": [
            "files/en-us/web/javascript/",
            "files/en-us/web/css/",
            "files/en-us/web/html/",
            "files/en-us/web/api/"
        ]
    },
    "Modern_JS_Tutorial": {
        "repo": "javascript-tutorial/en.javascript.info",
        "target_folder": "data/javascript_expert",
        "subpath": ""
    },
    "TypeScript_Docs": {
        "repo": "microsoft/TypeScript-website",
        "target_folder": "data/typescript_docs",
        "subpath": "packages/documentation/copy/en/"
    },

    # --- 7. Swift, SwiftUI, Metal & Apple HIG ---
    "Swift_Book": {
        "repo": "apple/swift-book",
        "target_folder": "data/swift_docs",
        "subpath": "TSPL.docc/"
    },
    "Swift_Evolution": {
        "repo": "apple/swift-evolution",
        "target_folder": "data/swift_docs",
        "subpath": "proposals/"
    },
    "Awesome_SwiftUI_Reference": {
        "repo": "alexiscreuzot/awesome-swiftui",
        "target_folder": "data/swift_docs",
        "subpath": ""
    },

    # --- 8. Semantic Versioning ---
    "Semantic_Versioning": {
        "repo": "semver/semver.org",
        "target_folder": "data/semver",
        "subpath": ""
    },

    # --- 9. Storybook Implementation ---
    "Storybook_Docs": {
        "repo": "storybookjs/storybook",
        "target_folder": "data/storybook",
        "subpath": "docs/"
    },
    "Storybook_Tutorials": {
        "repo": "storybookjs/tutorials",
        "target_folder": "data/storybook",
        "subpath": "content/"
    },

    # --- 10. Python & Framework Architecture ---
    "Python_Tutorials": {
        "repo": "python/cpython",
        "target_folder": "data/python_docs",
        "subpath": "Doc/tutorial/"
    },
    "FastAPI_Docs": {
        "repo": "fastapi/fastapi",
        "target_folder": "data/python_expert",
        "subpath": "docs/en/docs/"
    },
    "Python_Design_Patterns": {
        "repo": "faif/python-patterns",
        "target_folder": "data/python_expert",
        "subpath": ""
    },

    # --- 11. Computer Science & Architecture ---
    "OSSU_Computer_Science": {
        "repo": "ossu/computer-science",
        "target_folder": "data/computer_science",
        "subpath": ""
    },
    "CS_Interview_University": {
        "repo": "jwasham/coding-interview-university",
        "target_folder": "data/computer_science",
        "subpath": ""
    },
    "System_Design_Primer": {
        "repo": "donnemartin/system-design-primer",
        "target_folder": "data/system_architecture",
        "subpath": ""
    },
    "Node_Web_Best_Practices": {
        "repo": "goldbergyoni/nodebestpractices",
        "target_folder": "data/web_best_practices",
        "subpath": ""
    },

    # --- 12. Accessibility & WCAG ---
    "WCAG_Standards": {
        "repo": "w3c/wcag",
        "target_folder": "data/wcag",
        "subpath": "guidelines/"
    },
    "A11Y_Project": {
        "repo": "a11yproject/a11yproject.com",
        "target_folder": "data/wcag",
        "subpath": "src/content/"
    },

    # --- 13. IDE & CLI Tools ---
    "VS_Code_Docs": {
        "repo": "microsoft/vscode-docs",
        "target_folder": "data/vscode_docs",
        "subpath": "docs/"
    },
    "GitHub_Official_Docs": {
        "repo": "github/docs",
        "target_folder": "data/github_docs",
        "subpath": "content/get-started/"
    },
    "GitHub_CLI_Docs": {
        "repo": "cli/cli",
        "target_folder": "data/github_cli",
        "subpath": "docs/"
    }
}

def download_and_extract(name, config):
    target = config["target_folder"]
    
    if os.path.exists(target) and os.listdir(target):
        print(f"⏭️  {name} docs already exist in {target}. Skipping.")
        return
        
    print(f"\n📦 Downloading official docs for {name} ({config['repo']})...")
    
    zip_data = None
    successful_branch = None
    repo_name = config["repo"].split("/")[-1]

    # Try downloading across branch candidates
    for branch in BRANCH_CANDIDATES:
        url = f"https://codeload.github.com/{config['repo']}/zip/refs/heads/{branch}"
        req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
        try:
            with urllib.request.urlopen(req) as response:
                zip_data = response.read()
                successful_branch = branch
                break
        except urllib.error.HTTPError as e:
            if e.code == 404:
                continue
            print(f"⚠️ Network error for {name} on branch {branch}: {e}")
        except Exception as e:
            continue

    if not zip_data:
        print(f"❌ Failed to fetch {name}: Repository or branches not found.")
        return

    print(f"⚡ Extracting {name} (branch: '{successful_branch}') to {target}...")
    
    # Base prefix inside zip file
    zip_root = f"{repo_name}-{successful_branch}/"
    
    try:
        with zipfile.ZipFile(io.BytesIO(zip_data)) as z:
            count = 0
            for file_info in z.infolist():
                if file_info.is_dir():
                    continue

                # Build filter prefixes
                if "subpaths" in config:
                    prefixes = [f"{zip_root}{p}" for p in config["subpaths"]]
                elif config.get("subpath"):
                    prefixes = [f"{zip_root}{config['subpath']}"]
                else:
                    prefixes = [zip_root]

                is_target = any(file_info.filename.startswith(p) for p in prefixes)

                if is_target and file_info.filename.endswith(('.md', '.mdx', '.txt', '.json')):
                    # Strip the zip root folder prefix to maintain relative directory structure
                    relative_path = file_info.filename[len(zip_root):]
                    out_path = os.path.join(target, relative_path)
                    
                    os.makedirs(os.path.dirname(out_path), exist_ok=True)
                    with z.open(file_info) as source, open(out_path, "wb") as target_file:
                        target_file.write(source.read())
                    count += 1
                    
            print(f"✅ Saved {count} documentation files for {name}.")
    except Exception as e:
        print(f"❌ Failed to extract {name}: {e}")

def prepare_manual_folders():
    """Creates directories for personal PDFs and user profile memories."""
    folders = [
        "./data/nng_pdfs",
        "./data/pucrs_ux_pdfs",
        "./data/custom_books",
        "./memories"
    ]
    for folder in folders:
        os.makedirs(folder, exist_ok=True)

    bio_path = os.path.join(MEMORIES_DIR, "lio_profile.md")
    if not os.path.exists(bio_path):
        with open(bio_path, "w", encoding="utf-8") as f:
            f.write("# Category: Lio Profile & Preferences\n\n")
            f.write("- [2026-07-30] Lio's birthday is November 27, 1997.\n")
            f.write("- [2026-07-30] Lio is an M4 MacBook Air user developing Harvey local AI.\n")

if __name__ == "__main__":
    os.makedirs(DATA_DIR, exist_ok=True)
    os.makedirs(MEMORIES_DIR, exist_ok=True)
    prepare_manual_folders()
    
    print("🚀 Starting documentation download script...")
    for name, config in DOC_SOURCES.items():
        download_and_extract(name, config)
        
    print("\n🎉 All public documentation checked and downloaded!")
    print("💡 Next step: Run 'python ingest.py' to process the new files.")