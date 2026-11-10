# Publishing the source

This tree is prepared for a normal Git repository. No remote repository, commit, push, release or App Store submission is created by the preparation tools.

## Before publishing

- Run `python3 scripts/check_project.py` and the checks in `VALIDATION.md`. The preflight must pass. If it reports undownloaded cloud files, finish downloading the checkout before publishing.
- Keep your `src/Config/Signing.local.xcconfig` file local. It is ignored by Git.
- Do not add certificates, provisioning profiles, account containers, tokens, device logs or audio captures.
- Keep LICENSE, NOTICE and the dependency notices with the source and bundled libraries.
- Confirm that README accurately describes the private Dot protocol and account requirements.

## Upload method

Publish the repository root, including `src/`, `docs/`, `scripts/`, `README.md`, `LICENSE`, `NOTICE`, `.gitignore` and `.gitattributes`. Uploading `src/` alone omits the installation guide, license, notices and maintenance tools.

Use Git or GitHub Desktop to create a repository and push the tree. The bundled native static libraries let users build in Xcode without first installing Rust.

The preflight script enforces GitHub's regular-Git limit of 100 MiB per file. Some libraries exceed the 50 MiB warning threshold but remain below that hard limit. GitHub's browser file-upload limit is 25 MiB, so uploading these files individually through the website is not the appropriate method. See [GitHub's file-size documentation](https://docs.github.com/en/repositories/working-with-files/managing-large-files/about-large-files-on-github).

Do not replace real libraries with Git LFS pointer files unless the complete download and Xcode installation flow is also documented and tested. The current tree uses normal files and does not require Git LFS.

## What users download

Users download source code, resources and un-signed native libraries. They build and sign the Watch app and extension with their own Apple development identity. This repository does not provide a universally signed installer, enable Dot for unsupported accounts, or bypass Apple provisioning requirements.

This is a GPL-3.0-only derivative of Watch Dot. Preserve the upstream attribution and provide the modified source when distributing this version, along with the component notices. The generated waiting tone and its generator are included; extracted desktop-client resources are not.
