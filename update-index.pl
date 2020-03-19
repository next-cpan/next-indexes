#!/usr/bin/env perl

package UpdateIndex;

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

use LWP::UserAgent     ();
use File::Basename     ();
use CPAN::Meta::YAML   ();
use CPAN::DistnameInfo ();
use version            ();
use Net::GitHub::V3;

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

# settings.ini
has 'base_dir'     => ( isa => 'Str', is => 'ro', required => 1, documentation => 'REQUIRED - The base directory where our data is stored.' );                     # = /root/projects/pause-monitor
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
        warn "Cannot find '$build_file' from $repo\n";
        return;
    }

    my $decoded = MIME::Base64::decode_base64( $content->{content} );

    return $self->json->decode( $decoded );
}

sub run ($self) {

    my $base_dir = $self->base_dir;

    mkdir $base_dir unless -d $base_dir;

    my $repos = $self->github_repos;
    #note explain $repos;

    my $c = 0;
    foreach my $repo ( sort keys %$repos ) {        
        note "# repo $repo";
        $self->sleep_until_not_throttled; # check API rate limit

        next if $self->is_internal_repo( $repo );

        my $build = $self->get_build_info( $repo );

        note explain $build;

        last if ++$c > 2;
    }

    return 0;
}

sub DEBUG ($msg) {
    chomp $msg;
    print $msg . "\n";
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

    DEBUG( "        Rate remaining is $rate_remaining. Resets in " . ( time - $gh->rate_limit_reset() ) . " sec" ) if !$loop;

    $loop = $loop + 1 % 10;

    return;
}


package main;

my $ptgr = UpdateIndex->new_with_options( configfile => "${FindBin::Bin}/settings.ini" );

exit( $ptgr->run );

