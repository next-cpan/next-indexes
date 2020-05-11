# Introduction

This repository provides alternate index files to use CPAN modules without depending on PAUSE.

[https://next-cpan.github.io/next-indexes/](https://next-cpan.github.io/next-indexes/)

Rather than using distribution tarball from PAUSE itself, `play` is relying on GitHub infrastructure to download distributions.

[Browse the nextlist of all repositories](https://next-cpan.github.io/next-indexes/nextlist/nextlist-A.html)

This repo `next-indexes` host some index files which can be consumed to download and install most Perl modules.

`cplay` is the recommended CPAN client using these indexes and GitHub repositories.
You can read more about cplay client on the [cplay website](https://next-cpan.github.io/cplay/).

# List of index files

The index files in this repository are a replacement for the traditional index file [02packages.details.txt.gz](https://www.cpan.org/modules/02packages.details.txt.gz) used by CPAN and most/all CPAN clients.

You can download a tarball with all the .idx files using:
[https://github.com/next-cpan/next-indexes/archive/p5.tar.gz](https://github.com/next-cpan/next-indexes/archive/p5.tar.gz)

1. modules.idx
2. repositories.idx

You can also browse these files from:
[https://github.com/next-cpan/next-indexes/tree/p5](https://github.com/next-cpan/next-indexes/tree/p5)

## modules.idx

The `modules.idx` file lists the last available version of a module. For each module it indicates which distribution/repository provides it.

[https://raw.githubusercontent.com/next-cpan/next-indexes/p5/modules.idx](https://raw.githubusercontent.com/next-cpan/next-indexes/p5/modules.idx)

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
  ]
}
```

## repositories.idx

The `repositories.idx` file list the last available version of all CPAN distributions.
Each CPAN distribution is available from a repository.

[https://raw.githubusercontent.com/next-cpan/next-indexes/p5/repositories.idx](https://raw.githubusercontent.com/next-cpan/next-indexes/p5/repositories.idx)

For example `XML-Toolkit` distribution from [CPAN](https://metacpan.org/release/XML-Toolkit) is available on [next-cpan/XML-Toolkit](https://github.com/next-cpan/XML-Toolkit) repository:
[https://github.com/next-cpan/XML-Toolkit](https://github.com/next-cpan/XML-Toolkit)

For each distribution you can know:

- last available version
- sha used to download the tarball using the template url
- signature of the tarball

Sample extract:

```json
{
  "template_url": "https://github.com/next-cpan/:repository/archive/:sha.tar.gz",
  "version": 20200320203836,
  "columns": ["repository", "version", "sha", "signature"],
  "data": [
    [
      "A1z-HTML5-Template",
      "0.22",
      "01dc40b38e40f4f905bc7c902e2df08ccad22640",
      "f96dbc99fbb4dc833945c881c0f81925"
    ],
    [
      "A1z-Html",
      "0.003",
      "43484feee16a3ba360490890a203105525db91fb",
      "c54c2727eb29d7caab44d5e641491c4c"
    ],
    [
      "AC-MrGamoo",
      "1",
      "517730e24b94805eaf535b3ef4dbba9f776baaab",
      "7a598f9d71c1999063d91290f19523c5"
    ]
  ]
}
```

## Older and TRIAL releases

older distribution versions and TRIAL releases are not indexed.
We are going to use Git ID to download a custom state:

```
  https://github.com/next-cpan/:repository/archive/:sha.tar.gz

Example:

  https://github.com/next-cpan/:repository/archive/p5-v1.01.tar.gz 
  https://github.com/next-cpan/:repository/archive/p5-v1.02.tar.gz
  https://github.com/next-cpan/:repository/archive/p5-v1.02_01.tar.gz
```

# How to update the indexes:

## Installing dependencies:

In order to use `update-index.pl` you have to install first all dependencies required by the module.
This can be used by installing/using App::cpanminus and the cpanfile.

```sh
curl -L https://cpanmin.us | perl - App::cpanminus
cpanm --installdeps .
```

## Setup

### Git Repository Setup

The tools are provided in the master branch, whereas the index files are contained in the `p5` branch.

It's recommended to clone the repo in two different locations.
One directory is going to provide the tools whereas the other will points to the index files.

```sh
# the tools
git clone git@github.com:next-cpan/next-indexes.git next-indexes

# the index location
git clone git@github.com:next-cpan/next-indexes.git next-indexes-p5
cd next-indexes-p5
git checkout -t origin/p5
```

### settings.ini

In the `next-indexes@master` you will have to copy and adjust the `settings.ini` file.

```
cp settings.ini.sample settings.ini
# then adjust entries in the file
```

## How to refresh the index

The command `./update-index.pl` is going to parse all GitHub repositories for new distribution.

```sh
# refresh the index
./update-index.pl
```

You can also limit the number of repositories to check:

```sh
./update-index.pl --limit 5
```

### Updating a single repository

```sh
./update-index.pl --repo A1z-Html
```

### Perform a full update

```sh
./update-index.pl --full-update
```

# See Also

Also consider using traditional CPAN Clients, relying on PAUSE index:

- [cplay](https://next-cpan.github.io/cplay/) - CPAN client using next-cpan indexes
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

- [ ] minimal static website listing all available distribution/packages
- [ ] remove the repository_version from `modules.idx`
- [ ] use cplay itself instead of cpanm to install dependencies
