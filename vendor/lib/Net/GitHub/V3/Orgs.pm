package Net::GitHub::V3::Orgs;

use Moo;

our $VERSION   = '2.0';
our $AUTHORITY = 'cpan:FAYLAND';

use URI::Escape;

with 'Net::GitHub::V3::Query';

sub orgs {
    my ( $self, $user ) = @_;

    my $u = $user ? "/users/" . uri_escape($user) . '/orgs' : '/user/orgs';
    return $self->query($u);
}

sub next_org {
    my ( $self, $user ) = @_;

    my $u = $user ? "/users/" . uri_escape($user) . '/orgs' : '/user/orgs';
    return $self->next($u);
}

sub close_org {
    my ( $self, $user ) = @_;

    my $u = $user ? "/users/" . uri_escape($user) . '/orgs' : '/user/orgs';
    return $self->close($u);
}

## build methods on fly
my %__methods = (
    org        => { url => "/orgs/%s" },
    update_org => { url => "/orgs/%s", method => 'PATCH', args => 1 },

    # Members
    members               => { url => "/orgs/%s/members",                     paginate     => 1 },
    owner_members         => { url => "/orgs/%s/members?role=admin",          paginate     => 1 },
    no_2fa_members        => { url => "/orgs/%s/members?filter=2fa_disabled", paginate     => 1 },
    outside_collaborators => { url => "/orgs/%s/outside_collaborators",       paginate     => 1 },
    is_member             => { url => "/orgs/%s/members/%s",                  check_status => 204 },
    delete_member         => { url => "/orgs/%s/members/%s",                  method       => 'DELETE', check_status => 204 },
    public_members        => { url => "/orgs/%s/public_members",              paginate     => 1 },
    is_public_member      => { url => "/orgs/%s/public_members/%s",           check_status => 204 },
    publicize_member      => { url => "/orgs/%s/public_members/%s",           method       => 'PUT', check_status => 204 },
    conceal_member        => { url => "/orgs/%s/public_members/%s",           method       => 'DELETE', check_status => 204 },
    membership            => { url => "/orgs/:org/memberships/:username",     method       => 'GET', v => 2 },
    update_membership     => { url => "/orgs/:org/memberships/:username",     method       => 'PUT', args => 1, v => 2 },
    delete_membership     => { url => "/orgs/:org/memberships/:username",     method       => 'DELETE', check_status => 204, v => 2 },

    # Org Teams API
    teams              => { url => "/orgs/%s/teams", paginate => 1 },
    team               => { url => "/teams/%s" },
    create_team        => { url => "/orgs/%s/teams", method => 'POST', args => 1 },
    update_team        => { url => "/teams/%s", method => 'PATCH', args => 1 },
    delete_team        => { url => "/teams/%s", method => 'DELETE', check_status => 204 },
    team_members       => { url => "/teams/%s/members", paginate => 1 },
    is_team_member     => { url => "/teams/%s/members/%s", check_status => 204 },
    add_team_member    => { url => "/teams/%s/members/%s", method => 'PUT', check_status => 204 },
    delete_team_member => { url => "/teams/%s/members/%s", method => 'DELETE', check_status => 204 },
    team_maintainers   => { url => "/teams/%s/members?role=maintainer", paginate => 1 },
    team_repos         => { url => "/teams/%s/repos", paginate => 1 },
    is_team_repos      => { url => "/teams/%s/repos/%s", check_status => 204 },
    add_team_repos     => { url => "/teams/%s/repos/%s", method => 'PUT', args => 1, check_status => 204 },
    delete_team_repos  => { url => "/teams/%s/repos/%s", method => 'DELETE', check_status => 204 },

    # Org repos
    list_repos => { url => "/orgs/%s/repos", paginate => 1, method => 'GET', paginate => 1 },
);

__build_methods( __PACKAGE__, %__methods );

no Moo;

1;
__END__

=head1 NAME

Net::GitHub::V3::Orgs - GitHub Orgs API

=head1 SYNOPSIS

    use Net::GitHub::V3;

    my $gh = Net::GitHub::V3->new; # read L<Net::GitHub::V3> to set right authentication info
    my $org = $gh->org;

=head1 DESCRIPTION

=head2 METHODS

=head3 Orgs

L<http://developer.github.com/v3/orgs/>

=over 4

=item orgs

    my @orgs = $org->orgs(); # /user/org
    my @orgs = $org->orgs( 'nothingmuch' ); # /users/:user/org
    while (my $o = $org->next_org) { ...; }

=item org

    my $org  = $org->org('perlchina');

=item update_org

    my $org  = $org->update_org($org_name, { name => 'new org name' });

=back

=head3 Members

L<http://developer.github.com/v3/orgs/members/>

=over 4

=item members

=item is_member

=item delete_member

    my @members = $org->members('perlchina');
    while (my $m = $org->next_member) { ...; }
    my $is_member = $org->is_member('perlchina', 'fayland');
    my $st = $org->delete_member('perlchina', 'fayland');

=item public_members

=item is_public_member

=item publicize_member

=item conceal_member

    my @members = $org->public_members('perlchina');
    while (my $public_member = $org->next_public_member) { ...; }
    my $is_public_member = $org->is_public_member('perlchina', 'fayland');
    my $st = $org->publicize_member('perlchina', 'fayland');
    my $st = $org->conceal_member('perlchina', 'fayland');

=item owner_members

    my @admins = $org->owner_members('perlchina');
    while (my $admin = $org->next_owner_member) { ...; }

=item no_2fa_members

    my @no_2fa_members = $org->no_2fa_members('perlchina');
    while (my $n2a_m = $org->next_no_2fa_member) { ...; }

=item outside_collaborators

    my @collaborators = $org->outside_collaborators('perlchina');
    while (my $helper = $org->next_outside_collaborator) { ...; }

=item membership

=item update_membership

=item delete_membership

    my $membership = $org->membership( org => 'perlchina', username => 'fayland');
    my $membership = $org->update_membership('perlchina', 'fayland', {
        role => 'admin',
    });
    my $st = $org->delete_membership('perlchina', 'fayland');

=back

=head3 Org Teams API

L<http://developer.github.com/v3/orgs/teams/>

=over 4

=item teams

=item team

=item create_team

=item update_team

=item delete_team

    my @teams = $org->teams('perlchina');
    while (my $team = $org->next_team('perlchina')) { ...; }

    my $team  = $org->team($team_id);
    my $team  = $org->create_team('perlchina', {
        "name" => "new team"
    });
    my $team  = $org->update_team($team_id, {
        name => "new team name"
    });
    my $st = $org->delete_team($team_id);
    
=item team_members

=item is_team_member

=item add_team_member

=item delete_team_member

    my @members = $org->team_members($team_id);
    while (my $member = $org->next_team_member($team_id)) { ...; }
    my $is_team_member = $org->is_team_member($team_id, 'fayland');
    my $st = $org->add_team_member($team_id, 'fayland');
    my $st = $org->delete_team_member($team_id, 'fayland');

=item team_maintainers

    my @maintainers = $org->team_maintainers($team_id);
    while (my $maintainer = $org->next_team_maintainer($team_id)) { ...; }

=item team_repos

=item is_team_repos

=item add_team_repos

=item delete_item_repos

    my @repos = $org->team_repos($team_id);
    while (my $repo = $org->next_team_repo($team_id)) { ...; }

    my $is_team_repos = $org->is_team_repos($team_id, 'Hello-World');
    my $st = $org->add_team_repos($team_id, 'Hello-World');
    my $st = $org->add_team_repos($team_id, 'YoinkOrg/Hello-World', { permission => 'admin' });
    my $st = $org->add_team_repos($team_id, 'YoinkOrg/Hello-World', { permission => 'push' });
    my $st = $org->add_team_repos($team_id, 'YoinkOrg/Hello-World', { permission => 'pull' });
    my $st = $org->delete_team_repos($team_id, 'Hello-World');

=back

=head1 AUTHOR & COPYRIGHT & LICENSE

Refer L<Net::GitHub>
