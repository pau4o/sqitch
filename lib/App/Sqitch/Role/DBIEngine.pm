package App::Sqitch::Role::DBIEngine;

use 5.010;
use strict;
use warnings;
use utf8;
use Mouse::Role;
use Try::Tiny;
use App::Sqitch::X qw(hurl);
use Locale::TextDomain qw(App-Sqitch);
use namespace::autoclean;

our $VERSION = '0.954';

requires '_dbh';
requires 'sqitch';
requires 'plan';
requires '_regex_op';
requires '_ts2char_format';
requires '_char2ts';

sub _ts2char {
    my $format = $_[0]->_ts2char_format;
    sprintf $format => $_[1];
}

sub _dt($) {
    require App::Sqitch::DateTime;
    return App::Sqitch::DateTime->new(split /:/ => shift);
}

sub _log_tags_param {
    join ',' => map { $_->format_name } $_[1]->tags;
}

sub _log_requires_param {
    join ',' => map { $_->as_string } $_[1]->requires;
}

sub _log_conflicts_param {
    join ',' => map { $_->as_string } $_[1]->conflicts;
}

sub _cid {
    my ( $self, $ord, $offset, $project ) = @_;
    return try {
        $self->_dbh->selectcol_arrayref(qq{
            SELECT change_id
              FROM changes
             WHERE project = ?
             ORDER BY committed_at $ord
             LIMIT 1
            OFFSET COALESCE(?, 0)
        }, undef, $project || $self->plan->project, $offset)->[0];
    } catch {
        # Too bad $DBI::state isn't set to an SQL error coee. :-(
        return if $DBI::errstr eq 'no such table: changes';
        die $_;
    };
}

sub earliest_change_id {
    shift->_cid('ASC', @_);
}

sub latest_change_id {
    shift->_cid('DESC', @_);
}

sub current_state {
    my ( $self, $project ) = @_;
    my $cdtcol = $self->_ts2char('committed_at');
    my $pdtcol = $self->_ts2char('planned_at');
    my $dbh    = $self->_dbh;
    my $state  = $dbh->selectrow_hashref(qq{
        SELECT change_id
             , change
             , project
             , note
             , committer_name
             , committer_email
             , $cdtcol AS committed_at
             , planner_name
             , planner_email
             , $pdtcol AS planned_at
          FROM changes
         WHERE project = ?
         ORDER BY changes.committed_at DESC
         LIMIT 1
    }, undef, $project // $self->plan->project ) or return undef;
    $state->{committed_at} = _dt $state->{committed_at};
    $state->{planned_at}   = _dt $state->{planned_at};
    $state->{tags}         = $dbh->selectcol_arrayref(
        'SELECT tag FROM tags WHERE change_id = ? ORDER BY committed_at',
        undef, $state->{change_id}
    );
    return $state;
}

sub current_changes {
    my ( $self, $project ) = @_;
    my $cdtcol = $self->_ts2char('committed_at');
    my $pdtcol = $self->_ts2char('planned_at');
    my $sth    = $self->_dbh->prepare(qq{
        SELECT change_id
             , change
             , committer_name
             , committer_email
             , $cdtcol AS committed_at
             , planner_name
             , planner_email
             , $pdtcol AS planned_at
          FROM changes
         WHERE project = ?
         ORDER BY changes.committed_at DESC
    });
    $sth->execute($project // $self->plan->project);
    return sub {
        my $row = $sth->fetchrow_hashref or return;
        $row->{committed_at} = _dt $row->{committed_at};
        $row->{planned_at}   = _dt $row->{planned_at};
        return $row;
    };
}

sub current_tags {
    my ( $self, $project ) = @_;
    my $cdtcol = $self->_ts2char('committed_at');
    my $pdtcol = $self->_ts2char('planned_at');
    my $sth    = $self->_dbh->prepare(qq{
        SELECT tag_id
             , tag
             , committer_name
             , committer_email
             , $cdtcol AS committed_at
             , planner_name
             , planner_email
             , $pdtcol AS planned_at
          FROM tags
         WHERE project = ?
         ORDER BY tags.committed_at DESC
    });
    $sth->execute($project // $self->plan->project);
    return sub {
        my $row = $sth->fetchrow_hashref or return;
        $row->{committed_at} = _dt $row->{committed_at};
        $row->{planned_at}   = _dt $row->{planned_at};
        return $row;
    };
}

sub search_events {
    my ( $self, %p ) = @_;

    # Determine order direction.
    my $dir = 'DESC';
    if (my $d = delete $p{direction}) {
        $dir = $d =~ /^ASC/i  ? 'ASC'
             : $d =~ /^DESC/i ? 'DESC'
             : hurl 'Search direction must be either "ASC" or "DESC"';
    }

    # Limit with regular expressions?
    my (@wheres, @params);
    my $op = $self->_regex_op;
    for my $spec (
        [ committer => 'committer_name' ],
        [ planner   => 'planner_name'   ],
        [ change    => 'change'         ],
        [ project   => 'project'        ],
    ) {
        my $regex = delete $p{ $spec->[0] } // next;
        push @wheres => "$spec->[1] $op ?";
        push @params => $regex;
    }

    # Match events?
    if (my $e = delete $p{event} ) {
        my $qs = ('?') x @{ $e };
        push @wheres => "event IN ($qs)";
        push @params => $ { $e };
    }

    # Assemble the where clause.
    my $where = @wheres
        ? "\n         WHERE " . join( "\n               ", @wheres )
        : '';

    # Handle remaining parameters.
    my $limits = join '  ' => map {
        push @params => $p{$_};
        uc "\n         $_ ?"
    } grep { $p{$_} } qw(limit offset);

    hurl 'Invalid parameters passed to search_events(): '
        . join ', ', sort keys %p if %p;

    # Prepare, execute, and return.
    my $cdtcol = $self->_ts2char('committed_at');
    my $pdtcol = $self->_ts2char('planned_at');
    my $sth = $self->_dbh->prepare(qq{
        SELECT event
             , project
             , change_id
             , change
             , note
             , requires
             , conflicts
             , tags
             , committer_name
             , committer_email
             , $cdtcol AS committed_at
             , planner_name
             , planner_email
             , $pdtcol AS planned_at
          FROM events$where
         ORDER BY events.committed_at $dir$limits
    });
    $sth->execute(@params);
    return sub {
        my $row = $sth->fetchrow_hashref or return;
        $row->{committed_at} = _dt $row->{committed_at};
        $row->{planned_at}   = _dt $row->{planned_at};
        return $row;
    };
}

sub registered_projects {
    return @{ shift->_dbh->selectcol_arrayref(
        'SELECT project FROM projects ORDER BY project'
    ) };
}

sub register_project {
    my $self   = shift;
    my $sqitch = $self->sqitch;
    my $dbh    = $self->_dbh;
    my $plan   = $self->plan;
    my $proj   = $plan->project;
    my $uri    = $plan->uri;

    my $res = $dbh->selectcol_arrayref(
        'SELECT uri FROM projects WHERE project = ?',
        undef, $proj
    );

    if (@{ $res }) {
        # A project with that name is already registreed. Compare URIs.
        my $reg_uri = $res->[0];
        if ( defined $uri && !defined $reg_uri ) {
            hurl engine => __x(
                'Cannot register "{project}" with URI {uri}: already exists with NULL URI',
                project => $proj,
                uri     => $uri
            );
        } elsif ( !defined $uri && defined $reg_uri ) {
            hurl engine => __x(
                'Cannot register "{project}" without URI: already exists with URI {uri}',
                project => $proj,
                uri     => $reg_uri
            );
        } elsif ( defined $uri && defined $reg_uri ) {
            hurl engine => __x(
                'Cannot register "{project}" with URI {uri}: already exists with URI {reg_uri}',
                project => $proj,
                uri     => $uri,
                reg_uri => $reg_uri,
            ) if $uri ne $reg_uri;
        } else {
            # Both are undef, so cool.
        }
    } else {
        # Does the URI already exist?
        my $res = $dbh->selectcol_arrayref(
            'SELECT project FROM projects WHERE uri = ?',
            undef, $uri
        );

        hurl engine => __x(
            'Cannot register "{project}" with URI {uri}: project "{reg_prog}" already using that URI',
            project => $proj,
            uri     => $uri,
            reg_proj => $res->[0],
        ) if @{ $res };

        # Insert the project.
        $dbh->do(q{
            INSERT INTO projects (project, uri, creator_name, creator_email)
            VALUES (?, ?, ?, ?)
        }, undef, $proj, $uri, $sqitch->user_name, $sqitch->user_email);
    }

    return $self;
}

sub is_deployed_change {
    my ( $self, $change ) = @_;
    $self->_dbh->selectcol_arrayref(q{
        SELECT EXISTS(
            SELECT 1
              FROM changes
             WHERE change_id = ?
        )
    }, undef, $change->id)->[0];
}

sub are_deployed_changes {
    my $self = shift;
    my $qs = join ', ' => ('?') x @_;
    @{ $self->_dbh->selectcol_arrayref(
        "SELECT change_id FROM changes WHERE change_id IN ($qs)",
        undef,
        map { $_->id } @_,
    ) };
}

sub log_deploy_change {
    my ($self, $change) = @_;
    my $dbh    = $self->_dbh;
    my $sqitch = $self->sqitch;

    my ($id, $name, $proj, $user, $email) = (
        $change->id,
        $change->format_name,
        $change->project,
        $sqitch->user_name,
        $sqitch->user_email
    );

    $dbh->do(q{
        INSERT INTO changes (
              change_id
            , change
            , project
            , note
            , committer_name
            , committer_email
            , planned_at
            , planner_name
            , planner_email
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    }, undef,
        $id,
        $name,
        $proj,
        $change->note,
        $user,
        $email,
        $self->_char2ts( $change->timestamp ),
        $change->planner_name,
        $change->planner_email,
    );

    if ( my @deps = $change->dependencies ) {
        $dbh->do(q{
            INSERT INTO dependencies(
                  change_id
                , type
                , dependency
                , dependency_id
           ) VALUES
        } . join( ', ', ( q{(?, ?, ?, ?)} ) x @deps ),
            undef,
            map { (
                $id,
                $_->type,
                $_->as_string,
                $_->resolved_id,
            ) } @deps
        );
    }

    if ( my @tags = $change->tags ) {
        $dbh->do(q{
            INSERT INTO tags (
                  tag_id
                , tag
                , project
                , change_id
                , note
                , committer_name
                , committer_email
                , planned_at
                , planner_name
                , planner_email
           ) VALUES
        } . join( ', ', ( q{(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)} ) x @tags ),
            undef,
            map { (
                $_->id,
                $_->format_name,
                $proj,
                $id,
                $_->note,
                $user,
                $email,
                $self->_char2ts( $_->timestamp ),
                $_->planner_name,
                $_->planner_email,
            ) } @tags
        );
    }

    return $self->_log_event( deploy => $change );
}

sub log_fail_change {
    shift->_log_event( fail => shift );
}

sub _log_event {
    my ( $self, $event, $change, $tags, $requires, $conflicts) = @_;
    my $dbh    = $self->_dbh;
    my $sqitch = $self->sqitch;

    $dbh->do(q{
        INSERT INTO events (
              event
            , change_id
            , change
            , project
            , note
            , tags
            , requires
            , conflicts
            , committer_name
            , committer_email
            , planned_at
            , planner_name
            , planner_email
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
    }, undef,
        $event,
        $change->id,
        $change->name,
        $change->project,
        $change->note,
        $tags      || $self->_log_tags_param($change),
        $requires  || $self->_log_requires_param($change),
        $conflicts || $self->_log_conflicts_param($change),
        $sqitch->user_name,
        $sqitch->user_email,
        $self->_char2ts( $change->timestamp ),
        $change->planner_name,
        $change->planner_email,
    );

    return $self;
}

sub changes_requiring_change {
    my ( $self, $change ) = @_;
    return @{ $self->_dbh->selectall_arrayref(q{
        SELECT c.change_id, c.project, c.change, (
            SELECT tag
              FROM changes c2
              JOIN tags ON c2.change_id = tags.change_id
             WHERE c2.project      = c.project
               AND c2.committed_at >= c.committed_at
             ORDER BY c2.committed_at
             LIMIT 1
        ) AS asof_tag
          FROM dependencies d
          JOIN changes c ON c.change_id = d.change_id
         WHERE d.dependency_id = ?
    }, { Slice => {} }, $change->id) };
}

sub name_for_change_id {
    my ( $self, $change_id ) = @_;
    return $self->_dbh->selectcol_arrayref(q{
        SELECT change || COALESCE((
            SELECT tag
              FROM changes c2
              JOIN tags ON c2.change_id = tags.change_id
             WHERE c2.committed_at >= c.committed_at
               AND c2.project = c.project
             LIMIT 1
        ), '')
          FROM changes c
         WHERE change_id = ?
    }, undef, $change_id)->[0];
}

sub log_new_tags {
    my ( $self, $change ) = @_;
    my @tags   = $change->tags or return $self;
    my $sqitch = $self->sqitch;

    my ($id, $name, $proj, $user, $email) = (
        $change->id,
        $change->format_name,
        $change->project,
        $sqitch->user_name,
        $sqitch->user_email
    );

    # Insert one at a time, but only if they are not already present.
    my $sth = $self->_dbh->prepare(q{
        INSERT INTO tags (
               tag_id
             , tag
             , project
             , change_id
             , note
             , committer_name
             , committer_email
             , planned_at
             , planner_name
             , planner_email
        )
        SELECT ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
         WHERE NOT EXISTS (SELECT tag_id FROM tags WHERE tag_id = ?)
    });

    $sth->execute(
        $_->id,
        $_->format_name,
        $proj,
        $id,
        $_->note,
        $user,
        $email,
        $self->_char2ts( $_->timestamp ),
        $_->planner_name,
        $_->planner_email,
        $_->id,
    ) for @tags;

    return $self;
}

sub log_revert_change {
    my ($self, $change) = @_;
    my $dbh = $self->_dbh;
    my $cid = $change->id;

    # Retrieve and delete tags.
    my $del_tags = join ',' => @{ $dbh->selectcol_arrayref(
        'SELECT tag FROM tags WHERE change_id = ?',
        undef, $cid
    ) || [] };

    $dbh->do(
        'DELETE FROM tags WHERE change_id = ?',
        undef, $cid
    );

    # Retrieve dependencies and delete.
    my $sth = $dbh->prepare(q{
        SELECT dependency
          FROM dependencies
         WHERE change_id = ?
           AND type      = ?
    });
    my $req = join ',' => @{ $dbh->selectcol_arrayref(
        $sth, undef, $cid, 'require'
    ) };

    my $conf = join ',' => @{ $dbh->selectcol_arrayref(
        $sth, undef, $cid, 'conflict'
    ) };

    $dbh->do('DELETE FROM dependencies WHERE change_id = ?', undef, $cid);

    # Delete the change record.
    $dbh->do(
        'DELETE FROM changes where change_id = ?',
        undef, $cid,
    );

    # Log it.
    return $self->_log_event( revert => $change, $del_tags, $req, $conf );
}

sub begin_work {
    my $self = shift;
    # XXX Add some way to lock?
    $self->_dbh->begin_work;
    return $self;
}

sub finish_work {
    my $self = shift;
    $self->_dbh->commit;
    return $self;
}

sub rollback_work {
    my $self = shift;
    $self->_dbh->rollback;
    return $self;
}

1;

__END__

=head1 Name

App::Sqitch::Command::checkout - An engine based on the DBI

=head1 Synopsis

  package App::Sqitch::Engine::sqlite;
  extends 'App::Sqitch::Engine';
  with 'App::Sqitch::Role::DBIEngine';

=head1 Description

This role encapsulates the common attributes and methods required by
DBI-powered engines.

=head1 Interface

=head2 Instance Methods

=head3 C<earliest_change_id>

=head3 C<latest_change_id>

=head3 C<current_state>

=head3 C<current_changes>

=head3 C<current_tags>

=head3 C<search_events>

=head3 C<registered_projects>

=head3 C<register_project>

=head3 C<is_deployed_change>

=head3 C<are_deployed_changes>

=head3 C<log_deploy_change>

=head3 C<log_fail_change>

=head3 C<changes_requiring_change>

=head3 C<name_for_change_id>

=head3 C<log_new_tags>

=head3 C<log_revert_change>

=head1 See Also

=over

=item L<App::Sqitch::Engine::sqlite>

The SQLite engine.

=item L<App::Sqitch::Engine::pg>

The PostgreSQL engine.

=back

=head1 Author

David E. Wheeler <david@justatheory.com>

=head1 License

Copyright (c) 2012-2013 iovation Inc.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

=cut