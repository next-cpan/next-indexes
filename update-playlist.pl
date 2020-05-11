#!/usr/bin/env perl

package UpdateIndex;

use autodie;
use utf8;

use Test::More;    # for debugging
use FindBin;

BEGIN {
    unshift @INC, $FindBin::Bin . "/lib";
    unshift @INC, $FindBin::Bin . "/vendor/lib";
}

use Next::std;     # strict / warnings / signatures...
use Next::Logger;

use Moose;
with 'MooseX::SimpleConfig';
with 'MooseX::Getopt';

use experimental 'signatures';

use Template       ();
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

use MIME::Base64 ();
use JSON::XS     ();

use YAML::Syck;

# BEGIN {
#     $Net::GitHub::V3::Orgs::VERSION == '2.0'
#       or die("Need custom version of Net::GitHub::V3::Orgs to work!");
# }

use constant INTERNAL_REPO => qw{play-indexes pause-monitor cplay};

# main arguments
has 'limit' => ( is => 'rw', isa => 'Int', default => 0 );
has 'force' => (
    is            => 'rw', isa => 'Bool', default => 0,
    documentation => 'force refresh'
);

# settings.ini
has 'base_dir' => (
    isa           => 'Str', is => 'rw',
    default       => sub { Cwd::abs_path( $FindBin::Bin . "/.." ) },
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
has 'playlist_template' => (
    isa           => 'Str', is => 'rw', lazy => 1,
    default       => sub($self) { $self->playlist_html_dir . '/playlist.tt' },
    documentation => 'The template file for generating HTML'
);
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

has 'main_branch' => (
    isa           => 'Str', is => 'ro', default => 'p5',
    documentation => 'The main branch we are working on: p5, p7, ...'
);

has 'json' => (
    isa     => 'Object', is => 'ro', lazy => 1,
    default => sub { JSON::XS->new->utf8->pretty }
);

has 'tmp_dir' => (
    isa     => 'Object', is => 'ro', lazy => 1,
    default => sub { File::Temp->newdir() }
);

sub playlist_json_file_for_letter ( $self, $letter ) {
    return $self->playlist_json_dir . '/playlist-' . lc($letter) . '.json';
}

sub playlist_html_file_for_letter ( $self, $letter ) {
    return $self->playlist_html_dir . '/playlist-' . uc($letter) . '.html';
}

use constant BASE_URL    => q[https://github.com/pause-play];
use constant CPLAY_BADGE => BASE_URL . q[/:repo/workflows/install%20with/badge.svg?branch=p5];
use constant CPLAY_URL   => BASE_URL . q[/:repo/actions?query=branch%3Ap5];

sub refresh_all_html_file($self) {
    my @all_letters = ( 'A' .. 'Z', '0' );

    my $config = {

        #INCLUDE_PATH => '/search/path',  # or list ref
        INTERPOLATE => 1,    # expand "$var" in plain text
        POST_CHOMP  => 1,    # cleanup whitespace
                             #PRE_PROCESS  => 'header',        # prefix each template
                             #EVAL_PERL    => 1,               # evaluate Perl code blocks
        ABSOLUTE    => 1,

        #START_TAG => '[%',
        #END_TAG => '%]',
        TRIM => 0,
    };

    my $tt_file = $self->playlist_template;
    my $tt      = Template->new($config);

    my $status_yml = $self->root_dir . '/status.yml';
    my $status     = {};
    if ( -e $status_yml ) {
        $status = YAML::Syck::LoadFile($status_yml);
    }
    $status->{acknowledge} //= {};
    $status->{reason} = {};

    # convert acknowledge to a flat hash
    foreach my $k ( sort keys $status->{acknowledge}->%* ) {
        my $reason = $k;
        $reason =~ s{^-+\s*}{};
        $reason =~ s{\s*-+$}{};

        foreach my $module ( sort keys $status->{acknowledge}->{$k}->%* ) {
            $status->{reason}->{$module} = "$reason: " . $status->{acknowledge}->{$k}->{$module};
        }
    }

    foreach my $letter (@all_letters) {
        my $json_file = $self->playlist_json_file_for_letter($letter);
        my $html_file = $self->playlist_html_file_for_letter($letter);
        my $data      = {};

        my $mtime_json = ( stat($json_file) )[9] // 0;
        my $mtime_html = ( stat($html_file) )[9] // 0;

        next if !$self->force && $mtime_json < $mtime_html;

        INFO("Updating playlist for $letter");

        $data = $self->read_json_file($json_file) if -f $json_file;
        my @repos = map { $data->{$_} } sort { lc($a) cmp lc($b) } keys %$data;

        # setup urls
        foreach my $r (@repos) {
            my $name = $r->{name};
            $r->{url}              = BASE_URL . '/' . $name;
            $r->{url_cplay_action} = CPLAY_URL;
            $r->{url_cplay_badge}  = CPLAY_BADGE;

            $r->{url_cplay_action} =~ s{:repo}{$name}g;
            $r->{url_cplay_badge}  =~ s{:repo}{$name}g;

            $r->{reason} = $status->{reason}->{$name} // '';
        }

        my $vars = {
            letter      => uc $letter,
            all_letters => \@all_letters,
            repos       => \@repos,
        };

        $tt->process(
            $tt_file, $vars, $html_file,

            binmode => ':utf8'
        ) || die $tt->error;

    }

    return;
}

sub run ($self) {

    $self->refresh_all_html_file();

    return 0;
}

sub max ( $a, $b ) {
    return $a > $b ? $a : $b;
}

sub read_json_file ( $self, $file ) {
    local $/;
    open( my $fh, '<:utf8', $file ) or die;
    my $content = <$fh>;

    my $as_json = $self->json->decode($content) or die "fail to decode json content from $file";

    return $as_json;
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

    --force                   force updating index files even if no changes


Sample usages:

$0
$0 --force

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
