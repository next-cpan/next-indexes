#!/perl/bin/perl

package PauseToGithubRepo;

use strict;
use warnings;

use Moose;
with 'MooseX::SimpleConfig';
with 'MooseX::Getopt';

use experimental 'signatures';

use FindBin;

use LWP::UserAgent     ();
use File::Basename     ();
use CPAN::Meta::YAML   ();
use CPAN::DistnameInfo ();
use version            ();
use Net::GitHub::V3;
BEGIN { $Net::GitHub::V3::Orgs::VERSION == '2.0' or die("Need custom version of Net::GitHub::V3::Orgs to work!") }
use YAML::Syck   ();
use Git::Wrapper ();

use Parallel::ForkManager  ();
use IO::Uncompress::Gunzip ();
use Data::Dumper;

has 'base_dir'     => ( isa => 'Str', is => 'ro', required => 1, documentation => 'REQUIRED - The base directory where our data is stored.' );                     # = /root/projects/pause-monitor
has 'github_user'  => ( isa => 'Str', is => 'ro', required => 1, documentation => q{REQUIRED - The github username we'll use to create and update repos.} );       # = pause-parser
has 'github_token' => ( isa => 'Str', is => 'ro', required => 1, documentation => q{REQUIRED - The token we'll use to authenticate.} );
has 'github_org'   => ( isa => 'Str', is => 'ro', required => 1, documentation => q{REQUIRED - The github organization we'll be creating/updating repos in.} );    # = pause-play

has 'pause_cache_time'           => ( isa => 'Str',  is => 'ro', lazy => 1, default => 3600,                                documentation => 'The amount of time we cache 02packages.details.txt. Defaults to 3600 seconds (1 hour).' );
has 'parallel_downloads'         => ( isa => 'Int',  is => 'ro', lazy => 1, default => 40,                                  documentation => 'How many downloads we are going to attempt at one time.' );                                                         # = 40
has 'pause_base_url'             => ( isa => 'Str',  is => 'ro', lazy => 1, default => 'http://httpupdate.cpanel.net/CPAN', documentation => 'The base CPAN URL of upstream PAUSE. Defaults to http://httpupdate.cpanel.net/CPAN' );
has 'validate_existing_archives' => ( isa => 'Bool', is => 'ro', lazy => 1, default => 0,                                   documentation => 'Do we need to validate the existing archives before we start? This takes a little while so is off by default.' );
has 'git_binary'                 => ( isa => 'Str',  is => 'ro', lazy => 1, default => '/usr/bin/git',                      documentation => 'The location of the git binary that should be used.' );

has 'repo_user_name' => ( isa => 'Str', is => 'ro', required => 1, documentation => 'The name that will be on commits for this repo.' );
has 'repo_email'     => ( isa => 'Str', is => 'ro', required => 1, documentation => 'The email that will be on commits for this repo.' );

has 'parsed_pause_archives_file' => ( isa => 'Str', is => 'ro', lazy => 1, default => sub { $_[0]->base_dir . '/parsed_pause_archives.txt' } );
has 'tar_cache_dir'              => ( isa => 'Str', is => 'ro', lazy => 1, default => sub { my $d = $_[0]->base_dir . '/tar_cache'; -d $d or mkdir $d; return $d } );
has 'repos_dir'                  => ( isa => 'Str', is => 'ro', lazy => 1, default => sub { my $d = $_[0]->base_dir . '/repos'; -d $d or mkdir $d; return $d } );
has 'temp_repo_dir'              => ( isa => 'Str', is => 'ro', lazy => 1, default => sub { my $d = $_[0]->repos_dir . '/tmp'; -d $d or mkdir $d; return $d } );

has 'tarball_parsed_cache' => ( isa => 'HashRef', is => 'rw', lazy => 1, builder => '_build_tarball_parsed_cache' );

has 'gh'      => ( isa => 'Object', is => 'ro', lazy => 1, default => sub { Net::GitHub::V3->new( version => 3, login => $_[0]->github_user, access_token => $_[0]->github_token ) } );
has 'gh_org'  => ( isa => 'Object', is => 'ro', lazy => 1, default => sub { $_[0]->gh->org } );
has 'gh_repo' => ( isa => 'Object', is => 'ro', lazy => 1, default => sub { $_[0]->gh->repos } );

has 'github_repos' => (
    isa     => 'HashRef',
    is      => 'rw',
    lazy    => 1,
    default => sub {
        my %repos = map { $_->{'name'} => 1 } $_[0]->gh_org->list_repos( $_[0]->github_org );
        return \%repos;
    }
);

sub _build_tarball_parsed_cache ($self) {
    my %cache;

    if ( open( my $fh, '<', $self->parsed_pause_archives_file ) ) {
        while (<$fh>) {
            chomp;
            $cache{$_} = 1;
        }
    }

    return \%cache;
}

sub run ($self) {

    mkdir $self->base_dir;    # Make sure the base data dir is there.

    $self->stage_tarballs();
    $self->process_updates();

    return 0;
}

sub stage_tarballs ($self) {
    local $0 = "tarball_to_repo - Preparing to download archives.";

    my %tarball_requested;

    my $fh = $self->otwo_packages_fh();
    my @to_download;
    while ( my $line = <$fh> ) {
        my ( $module, $module_version, $author_path ) = split( qr/\s+/, $line );
        chomp $author_path;

        # The legacy pm files we're just going to ignore.
        next if $author_path =~ m/\.(?:pm|pm.gz)$/i;
        next if $self->archive_was_parsed($author_path);    # Skip download if we have already parsed the tarball.

        my $url          = $self->pause_base_url . "/authors/id/$author_path";
        my $tarball_file = $self->path_to_tarball_cache_file($author_path);

        # Have we have already determined we need this file?
        next if $tarball_requested{$tarball_file};
        $tarball_requested{$tarball_file} = 1;

        unlink $tarball_file if -z $tarball_file;

        next if ( -f $tarball_file && !$self->validate_existing_archives );    # No need to download it if we don't plan to validate it and it is there.

        push @to_download, [ $url, $tarball_file ];
    }

    $0 = "tarball_to_repo - Downloading and validating archives";
    my $pm = Parallel::ForkManager->new( $self->parallel_downloads );
    $pm->set_waitpid_blocking_sleep(0);

    my $files_validated = 0;
    foreach my $get (@to_download) {
        $files_validated++;

        $pm->start and next;

        my ( $url, $file ) = @$get;
        if ( -f $file ) {    # We can assume that we need to validate this.
            $0 = sprintf( "Validating %s", substr( $file, 6 + length( $self->tar_cache_dir ) ) );

            DEBUG("Validating ($files_validated) $file") if ( $files_validated % 100 == 0 );
            validate_archive($file) and $pm->finish;    # Nothing more to do if it is valid.

            DEBUG("$file was invalid!");
        }

        local $0 = sprintf( "Fetching %s", substr( $file, 6 + length( $self->tar_cache_dir ) ) );
        DEBUG($0);
        if ( !fetch_file( $url, $file ) || !validate_archive($file) ) {
            DEBUG("Re-downloading $url from $file");
            fetch_file( $url, $file ) && validate_archive($file);
        }
        $pm->finish;
    }
    $pm->wait_all_children;
}

sub validate_archive ($archive_file) {

    # Try to parse it.
    local $?;
    my $errors = '';
    if ( $archive_file =~ m/\.(?:tar\.[a-z]+|tar|tgz)$/i ) {    #.tar.gz or .tar.bz2 or .tar
        $errors = `/usr/bin/tar -tzf $archive_file 2>&1`;
    }
    elsif ( $archive_file =~ m/\.bz2$/ ) {
        $errors = `/usr/bin/tar -tjf $archive_file 2>&1`;
    }
    elsif ( $archive_file =~ m/\.zip$/ ) {
        $errors = `/usr/bin/unzip -q -t $archive_file 2>&1`;
    }
    else {
        unlink $archive_file;
        die("I don't know how to parse $archive_file");
    }

    return 1 if ( !$? );    # Nothing to do. The tarball is valid.

    warn "Got errors validating $archive_file with $? and $errors\n";

    # Remove it. It's invaalid.
    unlink $archive_file;

    return 0;
}

sub path_to_tarball_cache_file ( $self, $author_path ) {
    $author_path =~ s{/}{-}g;
    return $self->tar_cache_dir . '/' . $author_path;
}

sub otwo_packages_fh ($self) {
    my $otwofile = '02packages.details.txt';

    my $local_otwo_file = $self->base_dir . "/$otwofile";

    # Delete the cache if its over an hour (by default)
    my $pause_cache = ( $self->pause_cache_time // 0 + 0 ) || 60 * 60;
    my @age         = stat($local_otwo_file);
    if ( @age && $age[9] + $pause_cache < time ) {
        print "Removing cache $otwofile\n";
        unlink $otwofile;
    }

    if ( !-e $local_otwo_file ) {
        my $url = $self->pause_base_url . "/modules/$otwofile.gz";
        fetch_file( $url, "$local_otwo_file.gz" )
          or die "Failed to retrieve $local_otwo_file.gz";
        IO::Uncompress::Gunzip::gunzip( "$local_otwo_file.gz" => $local_otwo_file )
          or die "gunzip failed for $local_otwo_file.gz: ${IO::Uncompress::Gunzip::GunzipError}";
        unlink "$local_otwo_file.gz";
    }

    open( my $fh, '<', $local_otwo_file ) or die;

    # Read in and ignore the header.
    my $line = <$fh>;
    while ( $line =~ m/\S/ ) {
        $line = <$fh>;
    }

    return $fh;
}

sub fetch_file ( $url, $file ) {
    my $_ua = LWP::UserAgent->new( timeout => 10 );

    my $response = $_ua->mirror( $url, $file );

    if ( !$response->is_success ) {
        warn "Failed to download $file: " . $response->status_line;
        unlink "$file-$$";    # Temp file UA uses?
        return 0;
    }

    return 1;
}

sub DEBUG ($msg) {
    chomp $msg;
    print $msg . "\n";
}

sub process_updates ($self) {
    my $fh = $self->otwo_packages_fh();

    while ( my $line = <$fh> ) {
        my ( $module, $module_version, $author_path ) = split( qr/\s+/, $line );
        chomp $author_path;

        # The legacy pm files we're just going to ignore.
        next if $author_path =~ m/\.(?:pm|pm.gz)$/i;

        # If we have already processed the archive, then don't do it again.
        next if $self->archive_was_parsed($author_path);

        DEBUG("Processing $author_path for $module");
        my $tarball_file = $self->path_to_tarball_cache_file($author_path);

        my $extracted_distro_name = $self->expand_distro( $tarball_file, $author_path );

        $self->sleep_until_not_throttled();
    }

    return 0;
}

my $loop;

sub sleep_until_not_throttled ($self) {
    my $rate_remaining;

    $loop++;
    my $gh = $self->gh;

    while ( ( $rate_remaining = $gh->rate_limit_remaining() ) < 50 ) {
        my $time_to_wait = time - $gh->rate_limit_reset() + 1;
        $time_to_wait > 0 or die("time_remaining == $time_to_wait");
        $time_to_wait = int( $time_to_wait / 2 );
        DEBUG("Only $rate_remaining API queries are allowed for the next $time_to_wait seconds.");
        DEBUG("Sleeping until we can send more API queries");
        sleep 10;
        $gh->update_rate_limit();
    }

    DEBUG( "        Rate remaining is $rate_remaining. Resets at " . $gh->rate_limit_reset() ) if $loop % 10 == 0;

    return;
}

sub archive_was_parsed ( $self, $author_path ) {
    return $self->tarball_parsed_cache->{$author_path};
}

sub report_archive_parsed ( $self, $archive ) {
    $self->tarball_parsed_cache->{$archive} = 1;
    open( my $fh, '>>', $self->parsed_pause_archives_file ) or die( "Cannot open " . $self->parsed_pause_archives_file . " for write." );
    print {$fh} "$archive\n";
    close $fh;
    return;
}

sub expand_distro ( $self, $tarball_file, $author_path ) {
    $tarball_file or die;
    $author_path  or die;

    # Do we know how to process this file?
    my $tool;
    $tool = '/usr/bin/tar -xf' if $tarball_file =~ m/\.tar\.(gz|bz2)$|\.tgz$/i;
    $tool = '/usr/bin/unzip'   if $tarball_file =~ m/\.zip$/i;
    $tool or die("Don't know how to handle $tarball_file");

    # Setup the temp repo dir.
    my $temp_dir = $self->temp_repo_dir;
    `/bin/rm -rf "$temp_dir" 2>&1`;    # Just in case.
    mkdir($temp_dir) or die("Couldn't create temp dir $temp_dir");
    chdir $temp_dir  or die;

    my $untar_got   = `$tool "$tarball_file" 2>&1`;
    my $untar_error = $?;

    if ($untar_error) {
        DEBUG("Error extracting $tarball_file ($untar_error)");
        DEBUG($untar_got);
        die;
    }

    # Collapse all
    my @files = glob('*');
    if ( scalar @files == 1 && -d $files[0] ) {
        my $dir = $files[0];
        $dir && $dir !~ m/^\./ or die("Unexpected dir $dir");

        `find "$temp_dir" -name .git -exec /bin/rm -rf {} \\; 2>&1`;    # remove extracted .git dirs.
        `mv $temp_dir/"$dir"/* $temp_dir 2>&1`;
        `mv $temp_dir/"$dir"/.* $temp_dir 2>&1`;
        rmdir "$temp_dir/$dir" or die("Files unexpectedly found in $temp_dir/$dir");
    }
    elsif ( scalar @files ) {
        DEBUG("$tarball_file had no base dir????");
    }
    else {
        DEBUG("XXXX Could not find any extracted files for $tarball_file");
        die;
    }

    # Zero out the big files.
    #my @big_files = `find $temp_dir -type f -size +5M`;
    #foreach my $bigfile (@big_files) {
    #    chomp $bigfile;
    #    next if $bigfile =~ m{/sqlite3.c$}; # We're going to white list sqlite3.c
    #    open(my $fh, '>', $bigfile) or die ("Can't write to $bigfile?? $?");
    #    print {$fh} "The contents of this file exceeded 5MB and were deemed inappropriate for this repository.\n";
    #}

    # Read the meta file we just extracted and try to determine the distro dir.
    my ( $distro, $version ) = $self->determine_distro_and_version( $temp_dir, $author_path );
    $distro or die "$distro -- $version -- $author_path";

    my $repo_dir = $self->repos_dir . '/' . $distro;
    my ( undef, $existing_version ) = get_dist_version_from_meta_yaml("$repo_dir/META.yml");

    # If there's a repo dir there but we can't parse its META.yaml...
    if ( !length $existing_version && -d $repo_dir ) {
        $repo_dir or die("Couldn't parse version for existing $repo_dir");
    }

    # If we don't have a distro with an older version of this tarball.
    if ( compare( $existing_version // 0, '<', $version ) ) {    # TODO: This is probably fragile. if version schemes change, this could lead to versions being skipped.
        $self->add_extracted_tarball_from_tmp_to_repo( $distro, $version );
    }
    else {
        DEBUG("Skipping parse of $distro version $version. We already have version $existing_version");
    }

    $self->report_archive_parsed($author_path);

    return 0;
}

sub create_github_repo ( $self, $distro ) {
    my $rp = $self->gh_repo->create(
        {
            org         => $self->github_org,
            name        => $distro,
            description => "The CPAN Distro $distro",
            homepage    => "https://metacpan.org/release/$distro",
            has_issues  => 0,
        }
    );

    return if ( $rp && $rp->{'name'} eq $distro );
    DEBUG("Unexpected failure creating github repo $distro:");
    print Dumper $rp;
    die;
}

sub add_extracted_tarball_from_tmp_to_repo ( $self, $distro, $version ) {
    my $temp_dir  = $self->temp_repo_dir;
    my $repo_path = $self->repos_dir . '/' . $distro;

    my $git         = Git::Wrapper->new( { dir => $repo_path, git_binary => $self->git_binary } ) or die("Failed to create Git::Wrapper for $repo_path");
    my $just_cloned = 0;
    if ( !-d $repo_path ) {
        if ( !$self->github_repos->{$distro} ) {
            $self->create_github_repo($distro);
        }

        my $url = sprintf( "git\@github.com:%s/%s.git", $self->github_org, $distro );
        my $got = $git->clone( $url, $repo_path );
        $got and die("Unexpected exit code cloning $url to $repo_path");

        $just_cloned = 1;
        $git->config( 'user.name',  $self->repo_user_name );
        $git->config( 'user.email', $self->repo_email );
    }
    else {
        $git->checkout('PAUSE');
    }

    -d $repo_path or die("Can't proceed without a $repo_path dir");

    # Delete any old stuff.
    my @files = eval { $git->ls_files };
    if (@files) {
        eval { $git->rm( '-f', @files ) };

        # Just in case any files are remaining.
        eval { @files = $git->ls_files };
        if (@files) {
            foreach my $file (@files) {
                $git->rm( '-f', $file );
            }
            @files = $git->ls_files;
        }
        @files and die( "Unexpected files could not be deleted from $distro repo: " . Dumper \@files );
    }

    `/usr/bin/mv $temp_dir/* $repo_path/ 2>&1`;
    `/usr/bin/mv $temp_dir/.* $repo_path/ 2>&1`;
    rmdir $temp_dir or die( "Could not move all files from temp dir to $repo_path: " . `ls -al $temp_dir` );

    eval { $git->add('.') };
    eval { $git->commit( '-m', "Import $distro version $version from PAUSE" ) };

    # We only need to do this the first time since we couldn't create a branch and set upstream until we make our first commit.
    if ($just_cloned) {
        eval { $git->branch(qw/-m PAUSE/) };
        eval { $git->branch(qw/--unset-upstream/) };
        eval { $git->branch(qw/--track origin PAUSE/) };
    }

    eval { $git->push(qw/origin PAUSE/) };

    return 1;
}

sub determine_distro_and_version ( $self, $extracted_dir, $author_path ) {

    my $d       = CPAN::DistnameInfo->new($author_path);
    my $distro  = $d->dist;
    my $version = $d->version;

    # Is the version parseable?
    if ( $version and eval { version->parse($version); 1 } ) {
        return ( $distro, $version );
    }

    my $new_yaml = "$extracted_dir/META.yml";

    my ( $meta_name, $meta_version ) = get_dist_version_from_meta_yaml($new_yaml);

    # Couldn't parse meta. Just fall back to CPAN::DistnameInfo
    $meta_name or return ( $distro, $version );

    $meta_name =~ s/::/-/g;
    return ( $meta_name, $meta_version );
}

sub get_dist_version_from_meta_yaml ($file) {
    open( my $fh, "<:utf8", $file ) or return ( '', 0 );
    my $yaml_text = do { local $/; <$fh> };
    my $yaml      = CPAN::Meta::YAML->read_string($yaml_text) or return ( '', 0 );

    return ( $yaml->[0]->{'name'} // '', $yaml->[0]->{'version'} // 0 );
}

sub compare {
    my ( $left, $right ) = align( $_[0], $_[2] );
    my $cmp = $_[1];

    return $left gt $right if ( $cmp eq '>' );
    return $left lt $right if ( $cmp eq '<' );
    return ( $left gt $right or $left eq $right ) if ( $cmp eq '>=' );
    return ( $left lt $right or $left eq $right ) if ( $cmp eq '<=' );
    return $left eq $right if ( $cmp eq '=' );

    die("Unknown comparison: '$cmp' -- $_[0] $_[1] $_[2]");
}

sub align ( $left = '', $right = '' ) {

    # Leading/trailing whitespace.
    $_ =~ s/^\s+// foreach ( $left, $right );
    $_ =~ s/\s+$// foreach ( $left, $right );

    $left  = "0:$left"  if ( $left  !~ m/^\d*:/ && $right =~ /^\d*:/ );    # Insert 0 epoch if not on both.
    $right = "0:$right" if ( $right !~ m/^\d*:/ && $left  =~ /^\d*:/ );    # Insert 0 epoch if not on both.

    for ( $left, $right ) {
        $_ =~ "$_-0" if ( $_ !~ m/-\d+$/ );                                # Force a -0 version on each, similar to forcing an epoch.
    }

    # Split
    my (@left_array)  = split( /[\.\-\:]/, $left );
    my (@right_array) = split( /[\.\-\:]/, $right );

    # Pad each section with zeros or spaces.
    for my $seg ( 0 .. $#left_array ) {
        $right_array[$seg] = 0 if ( !$right_array[$seg] );                 # In case right is not set.

        my ( $left_len, $right_len ) = ( 0, 0 );
        $left_array[$seg] =~ m/^(\d+|^\D+)/
          and $left_len = length($1);
        $right_array[$seg] =~ m/^(\d+|^\D+)/
          and $right_len = length($1);

        if ( $left_len < $right_len ) {
            my $appender = $left_array[$seg] =~ m/^\d/ ? '0' : ' ';
            $left_array[$seg] = $appender x ( $right_len - $left_len ) . $left_array[$seg];
        }
        elsif ( $left_len > $right_len ) {
            my $appender = $right_array[$seg] =~ m/^\d/ ? '0' : ' ';
            $right_array[$seg] = $appender x ( $left_len - $right_len ) . $right_array[$seg];
        }
    }

    # Right segments length is > left segments length?
    for my $seg ( scalar @left_array .. $#right_array ) {
        $left_array[$seg] = "0" x length("$right_array[$seg]");
    }

    return ( join( "~", @left_array ), join( "~", @right_array ) );
}

package main;

my $ptgr = PauseToGithubRepo->new_with_options( configfile => "${FindBin::Bin}/settings.ini" );

exit( $ptgr->run );

__END__

print "Writing out distros to $settings->{base_dir}/distros\n";
chdir($settings->{'base_dir'}) or die($!);

my %processed_tarball;
my $fh = open_otwo_packages_file();
while (my $line = <$fh>) {
    my ($module, $module_version, $author_path) = split(qr/\s+/, $line);
    next if $author_path =~ m{\.pm\.gz$};
    next if $author_path =~ m{/Bundle-FinalTest2.tar.gz$};
    next if $author_path =~ m{/Spreadsheet-WriteExcel-WebPivot2.tar.gz$};
    next if $author_path =~ m{/perl5.00402-bindist04-msvcAlpha.tar.gz$};
    next if $author_path =~ m{/Geo-GoogleEarth-Document-modules2.tar.gz$};
    
    chomp $author_path;
    my $tarball_file = $self->path_to_tarball_cache_file($author_path);
        
    next if $processed_tarball{$tarball_file};
    $processed_tarball{$tarball_file} = 1;
    -f $tarball_file && !-z _ or die("ZERO TARBALL??? $tarball_file");
    
    next if was_parsed($author_path);

    DEBUG("Parsing $author_path");
    my $extracted_distro_name = expand_distro($tarball_file, $author_path);
}

exit;

my %tarball_parsed_cache;
sub was_parsed {
    my $author_path = shift or die;
    return 1 if $tarball_parsed_cache{$author_path};
    open(my $fh, '<', $tarball_parsed_file) or return 0;
    while (<$fh>) {
        chomp;
        $tarball_parsed_cache{$_} = 1;
    }

    return $tarball_parsed_cache{$author_path};
}

sub write_stored_version_info {
    my ($distro, $version, $author_path) = @_;
    $author_path or die("Can't write meta without author_path! $distro $version");
    $distro or die("Can't process $author_path without a distro");
    $version ||= 0;
    
    my $letter = substr($distro, 0, 1);

    mkdir "$distro_meta_dir/$letter";
    -d "$distro_meta_dir/$letter" or die ("Can't create directory $distro_meta_dir/$letter");
    
    my $distro_meta_dir 
    
    my $meta_file = "$distro_meta_dir/$letter/$distro.yml";

    open(my $fh, '>', $meta_file) or die "Can't write $meta_file";
    print {$fh} "---\ndistro: $distro\nversion: $version\nauthor_path: $author_path\n";
    close $fh;  
}







sub get_packages_info {
    my $fh = open_otwo_packages_file();
    
    my $packages = {};
    # Which files do we want to download and maintain??
    while (my $line = <$fh>) {
        my ($module, $module_version, $file) = split(qr/\s+/, $line);
        chomp $file;
        next if !length $module_version; # Means we didn't read it in.
        next if !length $file; # Means we didn't read it in.
        next if $module_version eq 'undef';
        next if ($file =~ m/\.pm\.gz$/i);
    
        my $distro_file = $file;
    
        $distro_file =~ s/\.pm\.gz$//; # https://github.com/andk/pause/issues/237
        
        my $d = CPAN::DistnameInfo->new($distro_file);
        my $distro = $d->dist || $distro_file;
        my $version = $d->version || $module_version;

        # Skip if we have a newer version for $distro already.
        next if( $packages->{$distro} && compare($packages->{$distro}->{'version'}, '>=', $version) );
    
#        $file =~ m/"/ and die("$file unexpectedly had a \" in it??");
        # Store it.
        $packages->{$distro} = {
            author => $d->cpanid,
            version => $version,
            author_path => $file,
            file => File::Basename::fileparse($file),
            distro => $distro,
        };
    }
    return $packages;
}





