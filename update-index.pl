#!/usr/bin/env perl

package UpdateIndex;

use autodie;
use strict;
use warnings;
use utf8;

use v5.28;

use Test::More;    # for debugging
use FindBin;

BEGIN {
    unshift @INC, $FindBin::Bin . "/lib";
    unshift @INC, $FindBin::Bin . "/vendor/lib";
}

use Moose;
with 'MooseX::SimpleConfig';
with 'MooseX::Getopt';

use experimental 'signatures';

use Cwd                ();
use DateTime           ();
use LWP::UserAgent     ();
use File::Basename     ();
use CPAN::Meta::YAML   ();
use CPAN::DistnameInfo ();
use version            ();
use Net::GitHub::V3;

use Crypt::Digest::MD5 ();
use IO::Socket::SSL    ();    # q/SSL_VERIFY_NONE/;
use Mojo::UserAgent    ();

use List::MoreUtils qw{zip};

use Git::Repository ();
use File::pushd;

use File::Temp ();
use File::Path;

use MIME::Base64 ();
use JSON::XS     ();

BEGIN {
    $Net::GitHub::V3::Orgs::VERSION == '2.0'
      or die("Need custom version of Net::GitHub::V3::Orgs to work!");
}

use YAML::Syck   ();
use Git::Wrapper ();

use Parallel::ForkManager  ();
use IO::Uncompress::Gunzip ();
use Data::Dumper;

use constant INTERNAL_REPO => qw{pause-index pause-monitor cplay};

# main arguments
has 'full_update' => ( is => 'rw', isa => 'Bool', default => 0 );
has 'push'        => (
    is              => 'rw', isa => 'Bool', default => 0,
    'documentation' => 'commit and push the index changes if needed'
);
has 'repo'  => ( is => 'rw', isa => 'ArrayRef', default => sub { [] } );
has 'limit' => ( is => 'rw', isa => 'Int',      default => 0 );
has 'force' => (
    is            => 'rw', isa => 'Bool', default => 0,
    documentation => 'force refresh one or more modules'
);

has 'playlist' => ( is => 'rw', isa => 'Bool', default => 1, documentation => 'enable or disable playlist processing' );

# settings.ini
has 'base_dir' => (
    isa           => 'Str', is => 'rw',
    default       => sub { Cwd::abs_path($FindBin::Bin) },
    documentation => 'The base directory where our idx files are stored.'
);
has 'root_dir' => (
    isa           => 'Str', is => 'rw',
    default       => sub { Cwd::abs_path($FindBin::Bin) },
    documentation => 'The base directory where the program lives.'
);
has 'playlist_html_dir' => (
    isa           => 'Str', is => 'rw', lazy => 1,
    default       => sub($self) { $self->root_dir . '/playlist' },
    documentation => 'The base directory where html files are stored for playlist'
);
has 'playlist_json_dir' => (
    isa           => 'Str', is => 'rw', lazy => 1,
    default       => sub($self) { $self->root_dir . '/playlist/json' },
    documentation => 'The base directory where json files are stored for playlist'
);
has 'github_user' => (
    isa           => 'Str', is => 'ro', required => 1,
    documentation => q{REQUIRED - The github username we'll use to create and update repos.}
);    # = pause-parser
has 'github_token' => (
    isa           => 'Str', is => 'ro', required => 1,
    documentation => q{REQUIRED - The token we'll use to authenticate.}
);
has 'github_org' => (
    isa           => 'Str', is => 'ro', required => 1,
    documentation => q{REQUIRED - The github organization we'll be creating/updating repos in.}
);    # = pause-play
has 'repo_user_name' => (
    isa           => 'Str', is => 'ro', required => 1,
    documentation => 'The name that will be on commits for this repo.'
);
has 'repo_email' => (
    isa           => 'Str', is => 'ro', required => 1,
    documentation => 'The email that will be on commits for this repo.'
);

has 'git_binary' => (
    isa           => 'Str', is => 'ro', lazy => 1, default => '/usr/bin/git',
    documentation => 'The location of the git binary that should be used.'
);

has 'gh' => (
    isa     => 'Object',
    is      => 'ro',
    lazy    => 1,
    default => sub {
        Net::GitHub::V3->new(
            version      => 3, login => $_[0]->github_user,
            access_token => $_[0]->github_token
        );
    }
);
has 'gh_org' => (
    isa     => 'Object', is => 'ro', lazy => 1,
    default => sub { $_[0]->gh->org }
);
has 'gh_repo' => (
    isa     => 'Object', is => 'ro', lazy => 1,
    default => sub { $_[0]->gh->repos }
);

has 'main_branch' => (
    isa           => 'Str', is => 'ro', default => 'p5',
    documentation => 'The main branch we are working on: p5, p7, ...'
);

has 'github_repos' => (
    isa     => 'HashRef',
    is      => 'rw',
    lazy    => 1,
    default => sub ($self) {
        return { map { $_->{'name'} => $_ } $self->gh_org->list_repos( $self->github_org ) };
    },
);

has 'idx_version' => ( isa => 'Str', is => 'ro', lazy => 1, builder => '_build_idx_version' );

has 'json' => (
    isa     => 'Object', is => 'ro', lazy => 1,
    default => sub { JSON::XS->new->utf8->pretty }
);

has 'template_url' => ( isa => 'Str', is => 'ro', lazy => 1, builder => '_build_template_url' );

has 'tmp_dir' => (
    isa     => 'Object', is => 'ro', lazy => 1,
    default => sub { File::Temp->newdir() }
);

has 'ix_git_repository' => (
    isa     => 'Object', is => 'ro', lazy => 1,
    default => sub($self) { Git::Repository->new( work_tree => $self->base_dir ); }
);

my $GOT_SIG_SIGNAL;
local $SIG{'INT'} = sub {
    if ($GOT_SIG_SIGNAL) {
        INFO("SIGINT sent twice... going to abort the program!");
        exit(1);
    }

    INFO("SIGINT requested, stopping parsing at the end of next repo. Please Wait!");
    $GOT_SIG_SIGNAL = 1;

    return;
};

sub _build_idx_version($self) {
    my $dt = DateTime->now;
    return $dt->ymd('') . $dt->hms('');
}

sub _build_template_url($self) {
    return q[https://github.com/] . $self->github_org . q[/:repository/archive/:sha.tar.gz];
}

sub is_internal_repo ( $self, $repository ) {
    $self->{_internal_repo} //= { map { $_ => 1 } INTERNAL_REPO };

    return $self->{_internal_repo}->{$repository};
}

sub get_build_info ( $self, $repository ) {

    my $build_file = 'BUILD.json';

    ## first get HEAD commit for the main_branch

    ## detect HEAD state
    my $HEAD;
    eval {
        my $api_answer = $self->gh->repos->commit(

            # FIXME move to v2 - once merged
            # GET /repos/:owner/:repo/commits/:ref
            $self->github_org, $repository, $self->main_branch
        );

        $HEAD = $api_answer->{sha};
    };

    if ( $@ || !defined $HEAD ) {
        ERROR( $repository, "fail to detect HEAD commit" );
        return;
    }

    ## retrieve build status
    my $build;
    eval {
        my $api_answer = $self->gh->repos->get_content(
            {
                owner => $self->github_org, repo => $repository,
                path  => $build_file
            },
            { ref => $HEAD }    # make sure we use the same state as HEAD
        );

        die q[No API answer from get_content] unless ref $api_answer;
        die q[No content from get_content]
          unless length $api_answer->{content};

        my $decoded = MIME::Base64::decode_base64( $api_answer->{content} );
        $build = $self->json->decode($decoded);
    };

    if ( $@ || !ref $build ) {
        ERROR( $repository, "Cannot find '$build_file'", $@ );
        return;
    }

    # add the sha to the build information
    $build->{sha} = $HEAD;

    return $build;
}

use Test::More;

sub setup ($self) {
    my @all_dirs = qw{base_dir};
    push @all_dirs, qw{playlist_html_dir playlist_json_dir} if $self->playlist;

    foreach my $dirtype (@all_dirs) {
        my $dir = $self->can($dirtype)->($self);
        if ( $dir =~ s{~}{$ENV{HOME}} ) {
            $self->can($dirtype)->( $self, $dir );    # update it
        }
        next if -d $dir;
        INFO("create missing directory for $dirtype");
        File::Path::mkpath($dir) or die "Cannot create directory $dir";
    }

    return;
}

sub run ($self) {

    $self->setup;

    if ( !$self->full_update ) {

        # read existing files
        $self->load_idx_files;
    }

    if ( $self->repo && scalar $self->repo->@* ) {

        foreach my $repository ( $self->repo->@* ) {
            INFO("refresh a repository $repository");
            $self->refresh_repository($repository);
        }
    }
    else {    # default
        $self->refresh_all_repositories();
    }

    # ... update files...
    $self->write_idx_files;
    $self->update_playlist_files;

    # commit
    return 1 unless $self->commit_and_push;

    return 0;
}

sub all_ix_files {
    return [qw{module.idx explicit_versions.idx repositories.idx}];
}

sub commit_and_push($self) {
    return 1 unless $self->push;

    my $r            = $self->ix_git_repository;
    my @all_ix_files = all_ix_files->@*;

    # do we have any diff
    my @out = $r->run( 'status', '-s', @all_ix_files );
    if ( !scalar @out ) {
        INFO("No changes to commit");
        return 1;
    }

    my $cmd;

    # commit
    my $version    = $self->idx_version;
    my $commit_msg = qq[Update indexes to version $version];
    $r->run( 'commit', '-m', $commit_msg, @all_ix_files, { quiet => 1 } );
    if ($?) {
        ERROR("Fail to commit index files");
        return;
    }

    # push
    $r->run( 'push', { quiet => 1 } );
    if ($?) {
        ERROR("Fail to push changes");
        return;
    }
    INFO("Pushed changes: $commit_msg");

    return 1;
}

# checkout file if version is the only change
sub check_ix_files_version($self) {
    my $in_dir = pushd( $self->base_dir );

    my $r = $self->ix_git_repository;

    my @all_ix_files = all_ix_files->@*;

    my $ix_with_version_only = 0;

    foreach my $ix (@all_ix_files) {
        if ( !-f $ix ) {
            ERROR("Index file $ix is missing");
            next;
        }
        my @out  = $r->run( 'diff', '-U0', $ix );
        my @diff = grep { m{^[-+]\s} } @out;
        if ( scalar @diff == 2 ) {

            # check if we only have some version change
            my @only_version = grep { m{^[-+]\s+"version"} } @diff;
            if ( scalar @only_version == scalar @diff ) {
                ++$ix_with_version_only;
            }
        }
    }

    # only checkout files if all files has only a version change
    if ( $ix_with_version_only == scalar @all_ix_files ) {
        $r->run( 'checkout', @all_ix_files, { quiet => 1 } );
        ERROR("Fail to checkout ix files") if $?;
    }

    return;
}

sub load_idx_files($self) {

    $self->load_module_idx();
    $self->load_explicit_versions_idx();
    $self->load_repositories_idx();

    return;
}

sub write_idx_files ( $self, %opts ) {

    $self->write_module_idx();
    $self->write_explicit_versions_idx();
    $self->write_repositories_idx();

    my $check = delete $opts{check} // 1;

    if ( scalar keys %opts ) {
        die q[Unknown options to write_idx_files: ] . join( ', ', sort keys %opts );
    }

    $self->check_ix_files_version if $check;

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

sub max ( $a, $b ) {
    return $a > $b ? $a : $b;
}

sub write_module_idx($self) {
    return $self->_write_idx(
        $self->_module_idx,
        undef,
        [qw{module version repository repository_version}],
        $self->{latest_module}
    );
}

sub load_module_idx($self) {
    my $rows = $self->_load_idx( $self->_module_idx ) or return;
    $self->{latest_module} = { map { $_->{module} => $_ } @$rows };

    return;
}

sub load_repositories_idx($self) {
    my $rows = $self->_load_idx( $self->_repositories_idx ) or return;

    $self->{repositories} = { map { $_->{repository} => $_ } @$rows };

    return;
}

sub load_explicit_versions_idx($self) {
    my $rows = $self->_load_idx( $self->_explicit_versions_idx ) or return;

    $self->{all_modules} =
      { map { $_->{module} . "||" . $_->{version} => $_ } @$rows };

    return;
}

sub read_json_file ( $self, $file ) {
    local $/;
    open( my $fh, '<:utf8', $file ) or die;
    my $content = <$fh>;

    my $as_json = $self->json->decode($content) or die "fail to decode json content from $file";

    return $as_json;
}

sub _load_idx ( $self, $file ) {

    return unless -e $file;

    my $idx = $self->read_json_file($file);

    my $columns = $idx->{columns} or die;
    my $data    = $idx->{data}    or die;

    my $rows = [];

    foreach my $line (@$data) {
        push @$rows, { zip( @$columns, @$line ) };
    }

    return $rows;
}

sub write_explicit_versions_idx($self) {
    my $template_url = $self->template_url;
    my $headers      = qq[ "template_url": "$template_url",];

    return $self->_write_idx(
        $self->_explicit_versions_idx,
        $headers,
        [qw{module version repository repository_version sha signature}],
        $self->{all_modules}
    );
}

sub write_repositories_idx($self) {
    my $template_url = $self->template_url;
    my $headers      = qq[ "template_url": "$template_url",];

    return $self->_write_idx(
        $self->_repositories_idx,
        $headers,
        [qw{repository version sha signature}],
        $self->{repositories}
    );
}

sub _write_idx ( $self, $file, $headers, $columns, $data ) {
    return unless $data && ref $data;

    die unless ref $columns eq 'ARRAY';

    my $json = $self->json->pretty(0)->space_after->canonical;

    open( my $fh, '>:utf8', $file ) or die;

    print {$fh} "{\n";
    if ($headers) {
        chomp $headers;
        print {$fh} $headers . "\n";
    }
    print {$fh} q[ "version": ] . $self->idx_version . ",\n";
    print {$fh} q[ "columns": ] . $json->encode($columns) . ",\n";
    print {$fh} q{ "data": [} . "\n";

    my @keys = sort keys $data->%*;
    my $c    = 0;
    foreach my $k (@keys) {
        ++$c;
        my $end = $c == scalar @keys ? "\n" : ",\n";
        print {$fh} "    " . $json->encode( [ map { $data->{$k}->{$_} } @$columns ] ) . $end;
    }

    print {$fh} " ] }\n";
    close($fh);

    # check if we can read the file
    $self->read_json_file($file);

    return;
}

sub _write_idx_txt ( $self, $file, $headers, $columns, $data ) {

    return unless $data && ref $data;

    die unless ref $columns eq 'ARRAY';

    my @L = map { length $_ } @$columns;
    $L[0] += 2;    # '# ' in front

    foreach my $k ( sort keys $data->%* ) {
        my @values = map { $data->{$k}->{$_} } @$columns;

        for ( my $i = 0; $i < scalar @L; ++$i ) {
            $L[$i] = max( $L[$i], length $values[$i] );
        }
    }

    @L = map { $_ + 1 } @L;    # add an extra space

    my $format = join( "\t", map { "%-${_}s" } @L );

    open( my $fh, '>:utf8', $file ) or die;
    if ($headers) {
        chomp $headers;
        print {$fh} $headers . "\n";
    }
    printf( $fh "# $format\n", @$columns );

    foreach my $k ( sort keys $data->%* ) {
        printf( $fh "$format\n", map { $data->{$k}->{$_} } @$columns );
    }

    return 1;
}

sub index_module (
    $self,               $module, $version, $repository,
    $repository_version, $sha,    $signature
) {

    # latest module Index: https://raw.githubusercontent.com/newpause/index_repo/p5/module.idx
    # module        version      repo
    # foo::bar::baz   1.000   foo-bar
    # foo::bar::biz   2.000   foo-bar

    $self->{latest_module} //= {};

    $self->{latest_module}->{$module} = {
        module             => $module,               # easier to write the file content
        version            => $version,
        repository         => $repository,           # or repo@1.0
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
        module             => $module,
        version            => $version,
        repository         => $repository,
        repository_version => $repository_version,
        sha                => $sha,
        signature          => $signature,
    };

    return;
}

sub index_repository (
    $self, $repository, $repository_version, $sha,
    $signature
) {

=pod
# latest distro index https://raw.githubusercontent.com/newpause/index_repo/p7/repositories.idx
# http://github.com/newpause/${distro}/archive/${sha}.tar.gz
distro     version   sha            signature
foo-bar  1.005     deadbeef   abcdef123435
=cut

    if ( index( $repository_version, '_' ) >= 0 ) {
        DEBUG( "$repository do not index development version: ", $repository_version, "in repositories.idx" );
        return;
    }

    $self->{repositories} //= {};
    $self->{repositories}->{$repository} = {
        repository => $repository,           ## maybe rename
        version    => $repository_version,
        sha        => $sha,
        signature  => $signature,
    };

    return;
}

sub compute_build_signature ( $self, $build ) {
    return unless ref $build;

    my $url = $self->template_url;

    my $repository = $build->{name} or die;
    my $sha        = $build->{sha}  or die;

    $url =~ s{:repository}{$repository};
    $url =~ s{:sha}{$sha};

    DEBUG( "... downloading:", $url );

    my $tmp_file = $self->tmp_dir . '/dist.tar.gz';

    if ( -e $tmp_file ) {
        unlink($tmp_file) or die "Fail to remove tmp_file: $tmp_file";
    }

    my $ua = Mojo::UserAgent->new;
    $ua->max_redirects(5)->get($url)->result->save_to($tmp_file);

    my $signature = Crypt::Digest::MD5::md5_file_hex($tmp_file);
    unlink($tmp_file);

    return $signature;
}

sub add_to_playlist ( $self, $build ) {

    return unless $self->playlist;

    my $letter = '0';              # default
    my $name   = $build->{name};

    # pick one letter
    $letter = lc($1) if $name =~ m{^([a-z])}i;

    $self->{playlist_index} //= {};

    $self->{playlist_index}->{$letter} //= $self->load_playlist_for_letter($letter);
    $self->{playlist_index}->{$letter}->{$name} = { map { $_ => $build->{$_} } qw{name primary version abstract} };

    return;
}

sub update_playlist_files( $self ) {

    return unless $self->playlist;

    DEBUG("Updating index files");
    my @all_letters = ( 'a' .. 'z', '0' );

    my $index = $self->{playlist_index} // {};

    use Test::More;
    note explain $index;

    foreach my $letter (@all_letters) {
        my $file = $self->playlist_json_file_for_letter($letter);

        my $data = $index->{$letter} // {};
        next unless scalar keys $data->%*;

        open( my $fh, '>:utf8', $file ) or die;
        print {$fh} $self->json->pretty(1)->encode($data);
    }

    return;
}

sub playlist_json_file_for_letter ( $self, $letter ) {
    return $self->playlist_json_dir . '/playlist-' . $letter . '.json';
}

sub load_playlist_for_letter ( $self, $letter ) {
    die unless defined $letter && length $letter == 1;
    my $file = $self->playlist_json_file_for_letter($letter);
    return {} unless -f $file;

    return $self->read_json_file($file);
}

sub refresh_repository ( $self, $repository ) {

    return if $self->is_internal_repo($repository);

    $self->sleep_until_not_throttled;    # check API rate limit

    my $build = $self->get_build_info($repository);
    return unless $build;

    my $repository_version = $build->{version};
    my $sha                = $build->{sha} or die "missing sha for $repository";

    if (  !$self->force
        && $self->{repositories}->{$repository}
        && defined $self->{repositories}->{$repository}->{sha}
        && $sha eq $self->{repositories}->{$repository}->{sha} ) {
        DEBUG( $repository, "no changes detected - skip" );
        return;
    }

    INFO( "refresh_repository", $repository );

    my $signature = $self->compute_build_signature($build);

    $self->index_repository(
        $repository,
        $repository_version,
        $sha,
        $signature,
    );

    my $provides = $build->{provides} // {};
    foreach my $module ( keys $provides->%* ) {
        my $version = $provides->{$module}->{version} // $repository_version;

        $self->index_module(
            $module,             $version, $repository,
            $repository_version, $sha,     $signature
        );
    }

    $self->add_to_playlist($build);

    return;
}

sub refresh_all_repositories($self) {
    my $all_repos = $self->github_repos;

    my $c     = 0;
    my $limit = $self->limit;

    foreach my $repository ( sort keys %$all_repos ) {
        $self->refresh_repository($repository);
        last if ++$c > $limit && $limit;
        if ($GOT_SIG_SIGNAL) {
            INFO("SIGINT received - Stopping parsing modules. Writting indexes to disk.");
            $self->write_idx_files;
            return;
        }
    }
    continue {
        if ( $c % 10 == 0 ) {    # flush from time to time idx on disk
            INFO("Updating indexes...");
            $self->write_idx_files( check => 0 );
        }
    }

    return;
}

sub _log(@args) {
    my $dt = DateTime->now;
    my $ts = $dt->ymd . ' ' . $dt->hms;

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
        $gh->update_rate_limit("...whatever...");    # bug in Net/GitHub/V3/Query.pm ' sub update_rate_limit'
    }

    DEBUG(
        "        Rate remaining is $rate_remaining. Resets in",
        ( time - $gh->rate_limit_reset() ), "sec"
    ) if !$loop;

    $loop = $loop + 1 % 10;

    return;
}

after 'print_usage_text' => sub {
    print <<EOS;

Options:

    --repo NAME [--repo NAME]        refresh only one or multiple repositories
    --push                           commit and push changes to index files
    --force                          force to refresh repositories even if HEAD is the same
    --full_update                    clear index before regenerating them
    --limit N                        stop after processing N repositories
    --noplaylist                     disable playlist json files updates

Sample usages:

$0                                    # refresh all modules
$0 --repo A1z-Html                    # only refresh a single repository
$0 --repo A1z-Html --push             # refresh a single repository and push
$0 --repo A1z-Html --force            # force refresh a repository
$0 --repo A1z-Html --repo ACL-Regex   # refresh multiple repositories
$0 --full_update                      # regenerate the index files
$0 --limit 5                          # stop after reading X repo
$0 --limit 5 --noplaylist             # do not update playlist json files

EOS
};

package main;

use strict;
use warnings;

$| = 1;

if ( !caller ) {
    my $settings_ini;
    foreach my $dir ( ${FindBin::Bin}, "${FindBin::Bin}/.." ) {
        $settings_ini = "$dir/settings.ini";
        last if -e $settings_ini;
        $settings_ini = undef;
    }

    die <<EOS unless $settings_ini;
# Cannot find a settings.ini file, please add one with the following content

github_user     = FIXME
github_token    = FIXME
github_org      = pause-play

repo_user_name  = pause-parser
repo_email      = FIXME

EOS

    my $update = UpdateIndex->new_with_options( configfile => $settings_ini );

    exit( $update->run );
}

1;
