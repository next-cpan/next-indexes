#!/usr/bin/env perl

package SetupActions;

use autodie;

use Test::More;    # for debugging
use FindBin;

BEGIN {
    unshift @INC, $FindBin::Bin . "/lib";
    unshift @INC, $FindBin::Bin . "/vendor/lib";
}

use Play::std;     # strict / warnings / signatures...
use Play::Logger;

use Moose;
with 'MooseX::SimpleConfig';
with 'MooseX::Getopt';

use experimental 'signatures';

use Cwd            ();
use DateTime       ();
use LWP::UserAgent ();
use File::Basename ();
use version        ();
use Net::GitHub::V3;

use Crypt::Digest::MD5 ();
use IO::Socket::SSL    ();    # q/SSL_VERIFY_NONE/;
use Mojo::UserAgent    ();

use List::MoreUtils qw{zip};

use Git::Repository ();
use File::pushd;

use File::Temp ();
use File::Path qw(mkpath rmtree);

use IPC::Run3 ();

use File::Slurper qw{read_text write_text};

use MIME::Base64 ();
use JSON::XS     ();

use YAML::Syck   ();
use Git::Wrapper ();

use Parallel::ForkManager  ();
use IO::Uncompress::Gunzip ();
use Data::Dumper;

use constant INTERNAL_REPO => qw{pause-index pause-monitor cplay};

use constant GITHUB_REPO_URL => q[https://github.com/:org/:repository];
use constant GITHUB_REPO_SSH => q[git@github.com::org/:repository.git];

# main arguments
has 'check' => ( is => 'ro', isa => 'Bool', default => 0 );
has 'setup' => ( is => 'ro', isa => 'Bool', default => 0 );

has 'full_update' => ( is => 'rw', isa => 'Bool', default => 0 );

has 'push' => (
    is              => 'rw', isa => 'Bool', default => 1,
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
has 'ix_base_dir' => (
    isa           => 'Str', is => 'rw',
    default       => sub { Cwd::abs_path($FindBin::Bin) },
    documentation => 'The base directory where our idx files are stored.'
);

has 'repo_base_dir' => (
    isa           => 'Str', is => 'rw', required => 1,
    documentation => 'The base directory where git repositories are stored.'
);

has 'ci_template_yml' => (
    isa           => 'Str', is => 'rw', lazy => 1,
    default       => sub($self) { read_text( $self->root_dir . '/templates/install-workflow.yml' ) },
    documentation => 'The template use for CI'
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
    documentation => q{REQUIRED - The github id.}
);    # = pause-parser

has 'github_author' => (
    isa           => 'Str', is => 'ro', required => 1,
    documentation => q{REQUIRED - The github author.}
);    # = pause-parser

has 'github_email' => (
    isa           => 'Str', is => 'ro', required => 1,
    documentation => q{REQUIRED - The github email.}
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

has 'cplay' => (
    isa           => 'Str', is => 'rw', required => 1,
    documentation => 'The location of the cplay fatpack script.'
);

has 'gh' => (
    isa     => 'Object',
    is      => 'ro',
    lazy    => 1,
    builder => '_build_gh',
);

sub _build_gh($self) {
    return Net::GitHub::V3->new(
        version      => 3,
        login        => $self->github_user,
        access_token => $self->github_token
    );
}

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
    default => sub($self) { Git::Repository->new( work_tree => $self->ix_base_dir ); }
);

has 'ix_git_repository' => (
    isa     => 'Object', is => 'ro', lazy => 1,
    default => sub($self) { Git::Repository->new( work_tree => $self->ix_base_dir ); }
);

has 'gh_workflow_dir' => ( isa => 'Str', is => 'ro', default => '.github/workflows' );

has 'gh_ci_workflow_file' => (
    isa     => 'Str',
    is      => 'ro',
    lazy    => 1,
    default => sub ($self) {

        #note $self->gh_workflow_dir . '/install-' . $self->main_branch . '.yml';
        $self->gh_workflow_dir . '/install-' . $self->main_branch . '.yml';
    }
);

has 'repositories_processed_file' => (
    isa     => 'Str',
    is      => 'ro',
    lazy    => 1,
    default => sub($self) {
        $self->repo_base_dir . '/processed.json';
    }
);
has 'repositories_processed' => ( isa => 'HashRef', is => 'ro', lazy => 1, builder => '_build_repositories_processed' );

sub _build_repositories_processed($self) {

    return {} unless -e $self->repositories_processed_file;

    my $content = read_text( $self->repositories_processed_file );

    return $self->json->decode($content);
}

# my $GOT_SIG_SIGNAL;
# local $SIG{'INT'} = sub {
#     if ($GOT_SIG_SIGNAL) {
#         INFO("SIGINT sent twice... going to abort the program!");
#         exit(1);
#     }

#     INFO("SIGINT requested, stopping parsing at the end of next repo. Please Wait!");
#     $GOT_SIG_SIGNAL = 1;

#     return;
# };

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

    # get the file content
    my ( $raw_content, $HEAD ) = $self->get_file_from_github( $repository, 'BUILD.json' );
    if ( !defined $raw_content ) {
        ERROR( $repository, "Cannot find BUILD.json from repository" );
        return;
    }

    # decode the json
    my $build;
    eval { $build = $self->json->decode($raw_content); 1 };
    if ( $@ || !ref $build ) {
        ERROR( $repository, "Cannot decode 'BUILD.json'", $@ );
        return;
    }

    # add the sha to the build information
    $build->{sha} = $HEAD;

    return $build;
}

sub get_file_from_github ( $self, $repository, $file ) {    # FIXME could add an optional sha argument

    die unless defined $repository && defined $file;

    DEBUG("GET file '$file' from repository '$repository'");

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
        ERROR( $repository, "fail to detect HEAD commit for $repository" );
        return;
    }

    ## retrieve build status
    my $raw_content;
    eval {
        my $api_answer = $self->gh->repos->get_content(
            {
                owner => $self->github_org, repo => $repository,
                path  => $file
            },
            { ref => $HEAD }    # make sure we use the same state as HEAD
        );

        die q[No API answer from get_content] unless ref $api_answer;
        die q[No content from get_content]
          unless length $api_answer->{content};

        $raw_content = MIME::Base64::decode_base64( $api_answer->{content} );
    };

    if ( $@ || !defined $raw_content ) {
        ERROR( $repository, "Cannot find '$file' from repository '$repository'", $@ );
        return;
    }

    return ( $raw_content, $HEAD ) if wantarray;
    return $raw_content;
}

sub check_ci_for_repository ( $self, $repository ) {
    $self->{status_ci} //= {};

    my $cplay_ready;
    {
        local $Play::Logger::QUIET = 1;
        $cplay_ready = $self->check_github_action_status_for_repository($repository);
    }

    return unless defined $cplay_ready;

    state $known_reasons = YAML::Syck::LoadFile( $self->root_dir . '/status/acknowledge.yml' );

    note explain $known_reasons;
    die;

    if ( $cplay_ready == 1 ) {
        OK("$repository");
        $self->{status_ci}->{$repository} = q[OK];
    }
    elsif ( $cplay_ready == -1 ) {
        ERROR("$repository failure: https://github.com/pause-play/${repository}/actions");
        $self->{status_ci}->{$repository} = qq[failure: https://github.com/pause-play/${repository}/actions];
    }

    $self->_write_status;

    return;
}

sub _write_status ( $self, $force = 0 ) {
    state $count = 0;
    ++$count;

    return if !$self->force && $count % 10 != 0;

    write_text( $self->root_dir . '/status/status.json', $self->json->encode( $self->{status_ci} ) );

    return;
}

sub init ($self) {
    my @all_dirs = qw{repo_base_dir};

    foreach my $dirtype (@all_dirs) {
        my $dir = $self->can($dirtype)->($self);
        if ( $dir =~ s{~}{$ENV{HOME}} ) {
            $self->can($dirtype)->( $self, $dir );    # update it
        }
        next if -d $dir;
        INFO("create missing directory for $dirtype");
        File::Path::mkpath($dir) or die "Cannot create directory $dir";
    }

    foreach my $name (qw{cplay}) {
        my $path = $self->can($name)->($self);
        if ( $path =~ s{~}{$ENV{HOME}} ) {
            $self->can($name)->( $self, $path );      # update it
        }
    }

    return;
}

sub run ($self) {

    $self->init;

    return $self->action_check_ci() if $self->check;
    return $self->action_setup_ci() if $self->setup;

    warn "No actions set: use --help, --setup or --check";
    warn $self->_print_usage_txt;
    return;
}

sub action_check_ci($self) {

    $Play::Logger::LOG_WITH_TIMESTAMP = 0;

    if ( $self->repo && scalar $self->repo->@* ) {
        foreach my $name ( $self->repo->@* ) {
            $self->check_ci_for_repository($name);
        }
    }
    else {    # default
        my $limit = $self->limit;
        my $c     = 0;
        while ( my $repository = $self->gh->org->next_repos( $self->github_org ) ) {
            ++$c;
            my $name = $repository->{name};
            $self->check_ci_for_repository($name);
            last if $limit && $c > $limit;
        }
    }

    $self->_write_status(1);

    return 0;
}

sub action_setup_ci($self) {

    if ( $self->repo && scalar $self->repo->@* ) {
        foreach my $repository ( $self->repo->@* ) {
            INFO("Setup CI for repository $repository");
            $self->setup_ci_for_repository($repository);
        }
    }
    else {    # default
        $self->setup_ci_for_all_repositories();
    }

    return 0;
}

sub max ( $a, $b ) {
    return $a > $b ? $a : $b;
}

sub read_json_file ( $self, $file ) {
    my $as_json;

    eval { $as_json = $self->_read_json_file( $file, 1, 0 ) }

      #eval      { $as_json = $self->_read_json_file( $file, 1 ) }
      #  or eval { $as_json = $self->_read_json_file( $file, 0 ) }
      or die "Fail to read file '$file': $@";

    return $as_json;
}

## FIXME cplay need to use the same rule
sub _read_json_file ( $self, $file, $as_utf8 = 1, $json_utf8 = -1 ) {
    local $/;

    $json_utf8 = $as_utf8 if $json_utf8 == -1;

    open( my $fh, '<' . ( $as_utf8 ? ':utf8' : '' ), $file ) or die;
    my $content = <$fh>;

    # we should always use utf8 = 0 when decoding
    return $self->json->utf8($json_utf8)->decode($content);
}

sub check_dependencies_cplay_ready ( $self, $build ) {
    return unless ref $build;

    #note explain $build;

    my @requires_keys = qw{requires_build requires_develop requires_runtime};

    #note $self->cplay;

    my %all_modules = map { $build->{$_}->%* } @requires_keys;

    #note explain \%all_modules;

    foreach my $module ( sort keys %all_modules ) {
        my $distro = $self->get_distro_for($module);
        DEBUG( "$module => " . ( $distro // 'undef' ) );
        next if defined $distro && ( $distro eq 'CORE' || $distro =~ m{^CORE\s} );
        if ( !defined $distro || $distro eq '-1' ) {
            DEBUG("no known distro for $module");
            return;
        }

        return unless $self->is_repository_cplay_ready($distro);

    }

    return 1;    # all dependencies satisfied
}

sub is_repository_cplay_ready ( $self, $repository ) {

    return unless defined $repository;

    # 1. first if we got a BUILD.json file in the github repo
    my $build;
    my $ok = eval { $build = $self->get_build_info($repository); 1 };
    if ( !$ok || !ref $build ) {
        DEBUG("repository $repository has no BUILD.json file.");
        return;
    }

    # 2. check if we got a .github/workflow/....yml file available
    my $gh_ci_workflow_file = $self->gh_ci_workflow_file;
    my $content;
    eval { $content = $self->get_file_from_github( $repository, $gh_ci_workflow_file ); };
    if ( !defined $content ) {
        DEBUG("repository $repository has no $gh_ci_workflow_file set");
        return;
    }

    my $gh_action_status = $self->check_github_action_status_for_repository($repository);
    return 1 if $gh_action_status && $gh_action_status == 1;
    return;
}

#$repository = 'cplay'; #HACK

sub check_github_action_status_for_repository ( $self, $repository ) {

    # 3. check if the workflow last run is a success
    my $workflows = $self->gh->actions->workflows( { owner => $self->github_org, repo => $repository } );
    return unless ref $workflows;

    #$workflows->{total_count} = 1; # HACK

    if ( $workflows->{total_count} == 1 ) {
        my $workflow    = $workflows->{workflows}->[0];
        my $workflow_id = $workflow->{id} or die "no workflow id";

        #note explain $workflow;

        my $runs = $self->gh->actions->runs( { owner => $self->github_org, repo => $repository, workflow_id => $workflow_id } );

        die explain($runs) unless ref $runs && ref $runs->{workflow_runs} && ref $runs->{workflow_runs}->[0];

        #note 'run: ', explain $runs->{workflow_runs}->[0];
        my $success;
        eval { $success = ( ( $runs->{workflow_runs}->[0]->{conclusion} // '' ) eq 'success' ? 1 : 0 ) };

        #note "success?? ", $success;
        DEBUG( "Last workflow run was a success ? " . ( $success // 'undef' ) );
        return 1 if $success;

        #die explain $runs->{workflow_runs}->[0];
        ERROR("$repository GitHub action failure");
        return -1;
    }
    else {
        ERROR("$repository has more than a single workflow.");

        #note explain $workflows;
        # more than a single workflow ? need to get one with the name
        return;
    }

    return;
}

sub get_distro_for ( $self, $module ) {
    $self->{_cache_module_distro} //= {};
    my $cache = $self->{_cache_module_distro};

    return $cache->{$module} if defined $cache->{$module};

    my ( $out, $err );
    my $cmd = [ $self->cplay, 'get-repo', $module ];
    IPC::Run3::run3( $cmd, undef, \$out, \$err );

    my $value = -1;    # used for errors
    chomp $out if defined $out;

    if ( $? == 0 ) {
        $value = $out;
    }

    $cache->{$module} = $value;

    return $cache->{$module};
}

sub setup_ci_for_repository ( $self, $repository ) {
    return if $self->is_internal_repo($repository);

    if ( !$self->force && $self->repositories_processed->{$repository} ) {
        DEBUG("Skipping already processed $repository");
        return;
    }

    my $ok = $self->_setup_ci_for_repository($repository);

    $self->tag_repository($repository);

    return $ok;
}

sub _setup_ci_for_repository ( $self, $repository, $attempt = 1 ) {

    $self->sleep_until_not_throttled;    # check API rate limit FIXME restore

    my $in_dir = pushd( $self->repo_base_dir );

    my $dir = $repository;
    if ( $self->force && -d $dir ) {
        INFO("Removing directory: $dir [--force]");
        rmtree($dir);
    }

    if ( -d $dir ) {
        INFO("Repository already cloned.");
        return;
    }

    # read the build file without cloning the repo
    my $build = $self->get_build_info($repository);
    return unless $build;

    #use constant GITHUB_REPO_URL => q[https://github.com/:org/:repository];
    my $org = $self->github_org;

    ### FIXME check the deps
    ### their repo and see if they are provided / green
    if ( !$self->check_dependencies_cplay_ready($build) ) {
        DEBUG("skipping $repository - dependencies not met");
        return;
    }

    my $url = GITHUB_REPO_SSH;
    $url =~ s{:org}{$org};
    $url =~ s{:repository}{$repository};

    INFO("Repository '$repository' -> $url");

    Git::Repository->run( clone => $url, $dir );
    -d $dir && -d "$dir/.git" or die q[Fail to clone repository $repository];

    {
        my $in_repo_dir = pushd($dir);

        # main_branch
        my $r              = Git::Repository->new( work_tree => '.' );
        my $current_branch = $r->run( 'branch', '--show-current' );

        if ( $current_branch ne $self->main_branch ) {
            undef $in_repo_dir;
            rmtree($dir);

            ERROR(
                sprintf(
                    "Repository %s not using '%s' as main branch [%s].",
                    $repository, $self->main_branch, $current_branch
                )
            );

            if ( $attempt == 1 ) {
                DEBUG("Trying to update default_branch");
                my $out = $self->gh->repos->update( $self->github_org, $repository, { default_branch => $self->main_branch } );

                if ( ref $out && $out->{default_branch} eq $self->main_branch ) {
                    INFO( "Altered $repository default_branch to " . $self->main_branch . " [retry]" );
                    return $self->_setup_ci_for_repository( $repository, $attempt + 1 );
                }
            }

            die "abort, abort...";
        }

        # load the BUILD.json file
        my $BUILD = $self->read_json_file('BUILD.json');

        INFO( "Setting username and email: " . $self->github_author . " / " . $self->github_email );
        $r->run( 'config', 'user.name',          $self->github_author );
        $r->run( 'config', 'user.email',         $self->github_email );
        $r->run( 'config', 'advice.ignoredHook', 'false' );

        my $gh_workflow_dir = $self->gh_workflow_dir;
        File::Path::mkpath($gh_workflow_dir);
        die "Cannot create directory $gh_workflow_dir for $repository" unless -d $gh_workflow_dir;

        my $primary     = $BUILD->{primary} or die "missing Primary module";
        my $main_branch = $self->main_branch;

        my $ci_template = $self->ci_template_yml;
        $ci_template =~ s{~MAIN_BRANCH~}{$main_branch}g;
        $ci_template =~ s{~PRIMARY~}{$primary}g;

        my $ci_file = $self->gh_ci_workflow_file;
        INFO("... write $ci_file");
        write_text( $ci_file, $ci_template );

        $r->run( 'add', $ci_file );
        $r->run( 'commit', '-m', "Add $main_branch CI workflow" );

        INFO("git push: $repository");
        my @out = $r->run('push');
    }

    return;
}

sub tag_repository ( $self, $repository ) {

    $self->repositories_processed->{$repository} = 1;

    my $as_json = $self->json->encode( $self->repositories_processed );
    write_text( $self->repositories_processed_file, $as_json );

    return;
}

sub setup_ci_for_all_repositories($self) {
    my $gh = $self->_build_gh;    # get its own object for pagination [maybe not needed?]

    my $c     = 0;
    my $limit = $self->limit;

    while ( my $repository = $gh->org->next_repos( $self->github_org ) ) {
        ++$c;
        my $name = $repository->{name};
        INFO( sprintf( "%04d %s", $c, $name ) );
        $self->setup_ci_for_repository($name);

        last if $limit && $c > $limit;
    }

    return;
}

# ....

sub sleep_until_not_throttled ($self) {
    my $rate_remaining;

    state $first = 1;
    state $loop  = 0;

    my $gh = $self->gh;

    while ( ( $rate_remaining = $gh->rate_limit_remaining() ) < 50 ) {
        my $time_to_wait = time - $gh->rate_limit_reset() + 1;
        $time_to_wait > 0 or die("time_remaining == $time_to_wait");
        $time_to_wait = int( $time_to_wait / 2 );
        DEBUG("Only $rate_remaining API queries are allowed for the next $time_to_wait seconds.");
        DEBUG("Sleeping until we can send more API queries");
        sleep 10 unless $first;
        $first = 0;
        $gh->update_rate_limit("...whatever...");    # bug in Net/GitHub/V3/Query.pm ' sub update_rate_limit'
    }

    DEBUG(
        "        Rate remaining is $rate_remaining. Resets in",
        ( time - $gh->rate_limit_reset() ), "sec"
    ) if !$loop;

    $loop = $loop + 1 % 10;

    return;
}

after 'print_usage_text' => \&_print_usage_txt;

sub _print_usage_txt {
    print <<EOS;

Options:

    --repo NAME [--repo NAME]        refresh only one or multiple repositories

Sample usages:

$0                                    # add github actions to repositories
$0 --repo A1z-Html                    # only add the actions to a single repository
$0 --check                            # check the status of the repositories

./setup-actions.pl --setup
./setup-actions.pl --check --limit 10

EOS
}

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

    my $update = SetupActions->new_with_options( configfile => $settings_ini );

    exit( $update->run // 0 );
}

1;
