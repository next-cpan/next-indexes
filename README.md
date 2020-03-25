# Introduction

This repository provides alternate index files to use CPAN modules without depending on PAUSE.

[https://pause-play.github.io/pause-index/](https://pause-play.github.io/pause-index/)

Rather than using distribution tarball from PAUSE itself, `play` is relying on GitHub infrastructure to download distributions.

This repo `pause-index` host some index files which can be consumed to download and install most Perl modules.

`cplay` is the recommended CPAN client using these indexes and GitHub repositories.
You can read more about cplay client on the [cplay website](https://pause-play.github.io/cplay/).

# List of index files

The index files in this repository are a replacement for the traditional index file `02packages.details.txt.gz` used by CPAN and most/all CPAN clients.

[https://www.cpan.org/modules/02packages.details.txt.gz](https://www.cpan.org/modules/02packages.details.txt.gz)

1. module.idx
2. repositories.idx
3. explicit_versions.idx

## module.idx

The `module.idx` file list the last available version of a module. For each module it indicates which distribution/repository provides it.

[https://pause-play.github.io/pause-index/module.idx](https://pause-play.github.io/pause-index/module.idx)

For every module you can know:
- the module version
- the repository(/CPAN distribution) providing this module
- the repository version # FIXME maybe useless...

```json
 {
 "version": 20200320203836,
 "columns": ["module", "version", "repository", "repository_version"],
 "data": [
    ["A1z::HTML5::Template", "0.22", "A1z-HTML5-Template", "0.22"],
    ["A1z::Html", "0.003", "A1z-Html", "0.003"],
    ["AC::MrGamoo", "1.0", "AC-MrGamoo", "1"],
    ["AC::MrGamoo::AC::FileList", 0, "AC-MrGamoo", "1"],
    ["AC::MrGamoo::AC::MySelf", 0, "AC-MrGamoo", "1"],
    ["AC::MrGamoo::AC::ReadInput", 0, "AC-MrGamoo", "1"]
 ] }
 ```

## repositories.idx

The `repositories.idx` file list the last available version of all CPAN distributions.
Each CPAN distribution is available from a repository.

[https://pause-play.github.io/pause-index/repositories.idx](https://pause-play.github.io/pause-index/repositories.idx)

For example `XML-Toolkit` distribution from [CPAN](https://metacpan.org/release/XML-Toolkit) is available on [pause-play/XML-Toolkit](https://github.com/pause-play/XML-Toolkit) repository:
[https://github.com/pause-play/XML-Toolkit](https://github.com/pause-play/XML-Toolkit)

For each distribution you can know:
- last available version
- sha used to download the tarball using the template url
- signature of the tarball

Sample extract:
```json
{
 "template_url": "https://github.com/pause-play/:repository/archive/:sha.tar.gz",
 "version": 20200320203836,
 "columns": ["repository", "version", "sha", "signature"],
 "data": [
    ["A1z-HTML5-Template", "0.22", "01dc40b38e40f4f905bc7c902e2df08ccad22640", "f96dbc99fbb4dc833945c881c0f81925"],
    ["A1z-Html", "0.003", "43484feee16a3ba360490890a203105525db91fb", "c54c2727eb29d7caab44d5e641491c4c"],
    ["AC-MrGamoo", "1", "517730e24b94805eaf535b3ef4dbba9f776baaab", "7a598f9d71c1999063d91290f19523c5"]
 ] }
```

## explicit_versions.idx

The `explicit_versions.idx` file list all versions published of a distribution.
It's useful to get for example an older or TRIAL version.

[https://pause-play.github.io/pause-index/explicit_versions.idx](https://pause-play.github.io/pause-index/explicit_versions.idx)

```json
{
 "template_url": "https://github.com/pause-play/:repository/archive/:sha.tar.gz",
 "version": 20200320203836,
 "columns": ["module", "version", "repository", "repository_version", "sha", "signature"],
 "data": [
    ["A1z::HTML5::Template", "0.22", "A1z-HTML5-Template", "0.22", "01dc40b38e40f4f905bc7c902e2df08ccad22640", "f96dbc99fbb4dc833945c881c0f81925"],
    ["A1z::Html", "0.003", "A1z-Html", "0.003", "43484feee16a3ba360490890a203105525db91fb", "c54c2727eb29d7caab44d5e641491c4c"]
 ] }
```

# Tools

## Installing App::cpanminus:

```sh
curl -L https://cpanmin.us | perl - App::cpanminus
```

## Installing dependencies:

```sh
cpanm --installdeps . --cpanfile tools/cpanfile
```

## How to refresh the index

The command `./tools/update-index.pl` is going to parse all GitHub repositories for new distribution.

```sh
# refresh the index
./tools/update-index.pl
```

You can also limit the number of repositories to check:
```sh
./tools/update-index.pl --limit 5
```

### Updating a single repository

```sh
./tools/update-index.pl --repo A1z-Html
```

### Perform a full update

```sh
./tools/update-index.pl --full-update
```

You can also use `--limit X`.

# See Also

Also consider using traditional CPAN Clients, relying on PAUSE index:

- [cplay](https://pause-play.github.io/cplay/) - CPAN client using pause-play indexes
- cpan
- [App::cpanminus](https://metacpan.org/pod/App::cpanminus) - get, unpack, build and install modules from CPAN
- [App::cpm](https://metacpan.org/pod/App::cpm) - a fast CPAN moduler installer

# Known issues

## installation

### Installing Crypt::SSLeay for Net::SSL on macOS

```
PERL_USE_UNSAFE_INC=1 perl Makefile.PL --incpath="/usr/local/Cellar/openssl@1.1/1.1.1d/include" --libpath="/usr/local/Cellar/openssl@1.1/1.1.1d/lib"
```

# TODO

- [X] use GitHub pages and update idx URLs to use GitHub CDN
- [ ] minimal static website listing all available distribution/packages
- [ ] remove the repository_version from `module.idx`
- [X] add a `version` field to the `.idx` files
- [X] add `template_url` field to get the URL to download the tarball
- [X] do not list trial versions in `distro.idx` file
- [ ] use cplay instead of cpanm to install dependencies
