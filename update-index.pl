#!/usr/bin/env perl

package UpdateIndex;

use autodie;
use strict;
use warnings;
use utf8;

use v5.28;

use Test::More; # for debugging
use FindBin;

BEGIN {
    unshift @INC, $FindBin::Bin . "/lib";
    unshift @INC, $FindBin::Bin . "/vendor/lib";
}

use Moose;
with 'MooseX::SimpleConfig';
with 'MooseX::Getopt';

use experimental 'signatures';

use DateTime           ();
use LWP::UserAgent     ();
use File::Basename     ();
use CPAN::Meta::YAML   ();
use CPAN::DistnameInfo ();
use version            ();
use Net::GitHub::V3;

use List::MoreUtils qw{zip};

use MIME::Base64 ();
use JSON::XS ();

BEGIN {
    $Net::GitHub::V3::Orgs::VERSION == '2.0' or die("Need custom version of Net::GitHub::V3::Orgs to work!");
}

use YAML::Syck   ();
use Git::Wrapper ();

use Parallel::ForkManager  ();
use IO::Uncompress::Gunzip ();
use Data::Dumper;

use constant INTERNAL_REPO => qw{pause-index pause-monitor};

# main arguments
has 'full_update' => ( is => 'rw', isa => 'Bool', default => 0 );
has 'repo'        => ( is => 'rw', isa => 'Str' );
has 'limit'       => ( is => 'rw', isa => 'Int', default => 0 );

# settings.ini
has 'base_dir'     => ( isa => 'Str', is => 'rw', required => 1, documentation => 'REQUIRED - The base directory where our data is stored.' );                     # = /root/projects/pause-monitor
has 'github_user'  => ( isa => 'Str', is => 'ro', required => 1, documentation => q{REQUIRED - The github username we'll use to create and update repos.} );       # = pause-parser
has 'github_token' => ( isa => 'Str', is => 'ro', required => 1, documentation => q{REQUIRED - The token we'll use to authenticate.} );
has 'github_org'   => ( isa => 'Str', is => 'ro', required => 1, documentation => q{REQUIRED - The github organization we'll be creating/updating repos in.} );    # = pause-play
has 'repo_user_name' => ( isa => 'Str', is => 'ro', required => 1, documentation => 'The name that will be on commits for this repo.' );
has 'repo_email'     => ( isa => 'Str', is => 'ro', required => 1, documentation => 'The email that will be on commits for this repo.' );

has 'git_binary'   => ( isa => 'Str',  is => 'ro', lazy => 1, default => '/usr/bin/git', documentation => 'The location of the git binary that should be used.' );

has 'gh'      => ( isa => 'Object', is => 'ro', lazy => 1, default => sub { Net::GitHub::V3->new( version => 3, login => $_[0]->github_user, access_token => $_[0]->github_token ) } );
has 'gh_org'  => ( isa => 'Object', is => 'ro', lazy => 1, default => sub { $_[0]->gh->org } );
has 'gh_repo' => ( isa => 'Object', is => 'ro', lazy => 1, default => sub { $_[0]->gh->repos } );

has 'main_branch' => ( isa => 'Str', is => 'ro', default => 'p5', documentation => 'The main branch we are working on: p5, p7, ...' );

has 'github_repos' => (
    isa     => 'HashRef',
    is      => 'rw',
    lazy    => 1,
    default => sub ($self) {
        return { map { $_->{'name'} => $_ } $self->gh_org->list_repos( $self->github_org ) };
    },
);

has 'json' => ( isa => 'Object', is => 'ro', lazy => 1, default => sub { JSON::XS->new->utf8->pretty } );

sub is_internal_repo($self, $repo) {
    $self->{_internal_repo} //= { map { $_ => 1 } INTERNAL_REPO };

    return $self->{_internal_repo}->{$repo};
}

sub get_build_info($self, $repo) {

    my $build_file = 'BUILD.json';

    my $content;
    eval {
         $content = $self->gh->repos->get_content(
            { owner => $self->github_org, repo => $repo, path => $build_file },
            { ref => $self->main_branch }
        );
    };
    if ( $@ || !ref $content || ! length $content->{content} ) {
        ERROR( "Cannot find '$build_file' from $repo" );
        return;
    }

    my $decoded = MIME::Base64::decode_base64( $content->{content} );
    my $build = $self->json->decode( $decoded );

    $build->{sha} = $content->{sha}; # add the sha to the build information

    return $build;
}

sub run ($self) {

    my $base_dir = $self->base_dir;
    if ( $base_dir =~ s{~}{$ENV{HOME}} ) {
        $self->base_dir($base_dir);
    }

    mkdir $base_dir unless -d $base_dir;

    if ( ! $self->full_update ) {
        # read existing files
        $self->load_idx_files;
    }

    if ( $self->repo ) {
        # refresh a single repo
        $self->refresh_repository( $self->repo );
    } else {
        # default
        $self->refresh_all_repositories();
    }

    # ... update files...
    $self->write_idx_files;

    return 0;
}

sub load_idx_files($self) {

    $self->load_module_idx();
    $self->load_explicit_versions_idx();
    $self->load_repositories_idx();

    return;
}

sub write_idx_files($self) {

    $self->write_module_idx();
    $self->write_explicit_versions_idx();
    $self->write_repositories_idx();

    return;
}

sub _module_idx($self) {
    return $self->base_dir() . '/module.idx';
}

sub _explicit_versions_idx($self) {
    return $self->base_dir() . '/explicit_versions.idx';
}

sub _repositories_idx($self) {
    return $self->base_dir() . '/repositories.idx';
}

sub max($a, $b) {
    return $a > $b ? $a : $b;
}

sub write_module_idx($self) {
    return $self->_write_idx(
        $self->_module_idx,
        undef,
        [ qw{module version repository repository_version} ],
        $self->{latest_module}
    );
}

sub load_module_idx($self) {

    my $rows = $self->_load_idx( $self->_module_idx );

    $self->{latest_module} = { map { $_->{module} => $_ } @$rows };

    return;
}

sub load_repositories_idx($self) {

    my $rows = $self->_load_idx( $self->_repositories_idx );

    $self->{repositories} = { map { $_->{repository} => $_ } @$rows };

    return;
}

sub load_explicit_versions_idx($self) {

    my $rows = $self->_load_idx( $self->_explicit_versions_idx );

    $self->{all_modules} = { map { $_->{module} . "||" . $_->{version} => $_ } @$rows };

    return;
}

sub _load_idx($self, $file) {
    my $idx;
    {
        local $/;
        open( my $fh, '<:utf8', $file ) or die;
        my $content = <$fh>;

        $idx = $self->json->decode( $content ) or die "Fail to decode file $file";
    }

    my $columns = $idx->{columns} or die;
    my $data    = $idx->{data} or die;

    my $rows = [];

    foreach my $line ( @$data ) {
        push @$rows, {
            zip( @$columns, @$line )
        };
    }

    return $rows;
}

sub write_explicit_versions_idx($self) {

    return $self->_write_idx(
        $self->_explicit_versions_idx,
        undef,
        [ qw{module version repository repository_version sha signature} ],
        $self->{all_modules}
    );
}

sub write_repositories_idx($self) {
    return $self->_write_idx(
        $self->_repositories_idx,
        undef,
        [ qw{repository version sha signature} ],
        $self->{repositories}
    );
}

sub _write_idx( $self, $file, $headers, $columns, $data ) {
    return unless $data && ref $data;

    die unless ref $columns eq 'ARRAY';

    my $json = $self->json->pretty(0)->space_after->canonical;

    open( my $fh, '>:utf8', $file ) or die;

    if ( $headers ) {
        chomp $headers;
        print {$fh} $headers . "\n";
    }

    print {$fh} "{\n";
    print {$fh} " " .q["columns": ] . $json->encode( $columns ) . ",\n";
    print {$fh} " " . qq{"data": [} ."\n";

    my @keys = sort keys $data->%*;
    my $c = 0;
    foreach my $k ( @keys ) {
        ++$c;
        my $end = $c == scalar @keys ? "\n" : ",\n";
        print {$fh} "    " . $json->encode( [ map { $data->{$k}->{$_} } @$columns ]  ) . $end;
    }

    print {$fh} " ] }\n";
    close($fh);

    {
        local $/;
        open( my $fh, '<:utf8', $file ) or die;
        my $content = <$fh>;

        $json->decode( $content ) or die "Fail to decode file $file";
    }

    return;
}

sub _write_idx_txt( $self, $file, $headers, $columns, $data ) {

    return unless $data && ref $data;

    die unless ref $columns eq 'ARRAY';

    my @L = map { length $_ } @$columns;
    $L[0] += 2; # '# ' in front

    foreach my $k ( sort keys $data->%* ) {
        my @values = map { $data->{$k}->{$_} } @$columns;

        for ( my $i = 0; $i < scalar @L; ++$i ) {
            $L[$i] = max( $L[$i], length $values[$i] );
        }
    }

    @L = map { $_ + 1 } @L; # add an extra space

    my $format = join( "\t", map { "%-${_}s" } @L );

    open( my $fh, '>:utf8', $file ) or die;
    if ( $headers ) {
        chomp $headers;
        print {$fh} $headers . "\n";
    }
    printf( $fh "# $format\n", @$columns );

    foreach my $k ( sort keys $data->%* ) {
        printf( $fh "$format\n", map { $data->{$k}->{$_} } @$columns );
    }

    return 1;
}

sub index_module($self, $module, $version, $repository, $repository_version, $sha ) {
# latest module Index: https://raw.githubusercontent.com/newpause/index_repo/p5/module.idx
# module        version      repo
# foo::bar::baz   1.000   foo-bar
# foo::bar::biz   2.000   foo-bar

    $self->{latest_module} //= {};

    $self->{latest_module}->{$module} = {
        module     => $module, # easier to write the file content
        version    => $version,
        repository => $repository,  # or repo@1.0
        repository_version => $repository_version,
    };

# all module version Index: https://raw.githubusercontent.com/newpause/index_repo/p5/explicit_versions.idx
# module    version        repo  repo_version sha signature
# foo::bar::baz   1.000  foo-bar 1.000 deadbeef   abcdef123435
# foo::bar::baz   0.04_01  foo-bar deadbaaf
# foo::bar::biz    2.000  foo-bar deadbeef

    $self->{all_modules} //= {};

    my $key = "$module||$version";

    $self->{all_modules}->{$key} = {
        module => $module,
        version => $version,
        repository => $repository,
        repository_version => $repository_version,
        sha => $sha,
        signature => q[***signature***],
    };

    return;
}

sub index_repository($self, $repository, $repository_version, $sha, $signature) {
=pod
# latest distro index https://raw.githubusercontent.com/newpause/index_repo/p7/distros.idx
# http://github.com/newpause/${distro}/archive/${sha}.tar.gz
distro     version   sha            signature
foo-bar  1.005     deadbeef   abcdef123435
=cut

    $self->{repositories} //= {};
    $self->{repositories}->{$repository} = {
        repository => $repository, ## maybe rename
        version    => $repository_version,
        sha => $sha,
        signature => $signature,
    };

    return;
}

sub refresh_repository($self, $repository) {

    return if $self->is_internal_repo( $repository );

    INFO( "refresh_repository", $repository );

    $self->sleep_until_not_throttled; # check API rate limit

    my $build = $self->get_build_info( $repository );
    return unless $build;

    my $repository_version = $build->{version};
    my $sha = $build->{sha} or die "missing sha for $repository";

    $self->index_repository(
        $repository,
        $repository_version,
        $sha,
        q[***signature***],
    );

    my $provides = $build->{provides} // {};
    foreach my $module ( keys $provides->%* ) {
        my $version = $provides->{$module}->{version} // $repository_version;

        $self->index_module(
            $module, $version, $repository, $repository_version, $sha
        );
    }

    #note explain $build;

    return;
}

sub refresh_all_repositories($self) {
    my $all_repos = $self->github_repos;

    my $c = 0;
    my $limit = $self->limit;

    foreach my $repository ( sort keys %$all_repos ) {
        $self->refresh_repository( $repository );
        last if ++$c > $limit && $limit;
    } continue {
        if ( $c % 10 == 0 ) { # flush from time to time idx on disk
            INFO("Updating indexes...");
            $self->write_idx_files;
        }
    }

    return;
}

sub _log(@args) {
    my $dt     = DateTime->now;
    my $ts    = $dt->ymd . ' ' . $dt->hms;

    my $msg = join( ' ', "[${ts}]", grep { defined $_ } @args );
    chomp $msg;
    $msg .= "\n";

    print STDERR $msg;
    ### .. log to an error file

    return $msg;
}

sub INFO (@what) {
    _log( '[INFO]', @what );

    return;
}


sub DEBUG (@what) {
    _log( '[DEBUG]', @what );

    return;
}

sub ERROR (@what) {
    _log( '[ERROR]', @what );
    return;
}

sub sleep_until_not_throttled ($self) {
    my $rate_remaining;

    state $loop = 0;

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

    DEBUG( "        Rate remaining is $rate_remaining. Resets in", ( time - $gh->rate_limit_reset() ), "sec" ) if !$loop;

    $loop = $loop + 1 % 10;

    return;
}

after 'print_usage_text'  => sub {
    print <<EOS

Sample usages:

$0                  refresh all modules
$0 --repo Foo       only refresh a single repository
$0 --full_update    regenerate the index files
$0 --limit 5        stop after reading X repo

EOS
};

package main;

use strict;
use warnings;

$| = 1;

if ( ! caller ) {
    my $update = UpdateIndex->new_with_options( configfile => "${FindBin::Bin}/settings.ini" );

    exit( $update->run );
}

1;