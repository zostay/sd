package App::SD::Replica::gcode::PullEncoder;
use Any::Moose;
extends 'App::SD::ForeignReplica::PullEncoder';

use Params::Validate qw(:all);
use Memoize;
use Time::Progress;
use DateTime;

has sync_source => (
    isa => 'App::SD::Replica::gcode',
    is  => 'rw',
);

my %PROP_MAP = %App::SD::Replica::gcode::PROP_MAP;

sub ticket_id {
    my $self   = shift;
    return shift->id;
}

sub _translate_final_ticket_state {
    my $self   = shift;
    my $ticket = shift;

    my $ticket_data = {
        $self->sync_source->uuid . '-id' => $ticket->id,
        owner                            => $ticket->owner,
        created     => $ticket->reported->ymd . ' ' . $ticket->reported->hms,
        reporter    => $ticket->reporter,
        status      => $self->translate_prop_status( $ticket->status ),
        summary     => $ticket->summary,
        description => $ticket->description,
        tags        => (join ', ', @{$ticket->labels}),
        cc          => $ticket->cc,
    };

    # delete undefined and empty fields
    delete $ticket_data->{$_}
      for grep { !defined $ticket_data->{$_} || $ticket_data->{$_} eq '' }
      keys %$ticket_data;

    return $ticket_data;
}

=head2 find_matching_tickets QUERY

Returns a array of all tickets found matching your QUERY hash.

=cut

sub find_matching_tickets {
    my $self                   = shift;
    my %query                  = (@_);
    my $last_changeset_seen_dt = $self->_only_pull_tickets_modified_after();
    $self->sync_source->log("Searching for tickets");
    require Net::Google::Code::Issue::Search;
    my $search = Net::Google::Code::Issue::Search->new(
        project => $self->sync_source->project,
        limit   => '99999',
        _can    => 'all',
    );
    $search->search( _q => $query{query} );
    my @base_results = @{ $search->results };
    my @results;

    foreach my $item (@base_results) {
        if ( !$last_changeset_seen_dt
            || ( $item->updated >= $last_changeset_seen_dt ) )
        {
            push @results, $item;
        }
    }
    return \@results;
}

sub translate_ticket_state {
    my $self         = shift;
    my $ticket       = shift;
    my $transactions = shift;

    my $final_state   = $self->_translate_final_ticket_state($ticket);
    my %earlier_state = %{$final_state};

    for my $txn ( sort { $b->{'serial'} <=> $a->{'serial'} } @$transactions ) {
        $txn->{post_state} = {%earlier_state};

        if ( $txn->{serial} == 0 ) {
            $txn->{pre_state} = {};
            last;
        }

        my $updates = $txn->{object}->updates;

        for my $prop (qw(owner status labels cc summary)) {
            next unless exists $updates->{$prop};
            my $values = delete $updates->{$prop};
            for my $value ( ref($values) eq 'ARRAY' ? @$values : $values ) {
                if ( my $sub = $self->can( 'translate_prop_' . $prop ) ) {
                    $value = $sub->( $self, $value );
                }

                if ( $value =~ /^-(.*)$/ ) {
                    $value = $1;
                    $earlier_state{ $PROP_MAP{$prop} } =
                      $self->warp_list_to_old_value(
                        $earlier_state{ $PROP_MAP{$prop} },
                        undef, $value );
                }
                else {
                    $earlier_state{ $PROP_MAP{$prop} } =
                      $self->warp_list_to_old_value(
                        $earlier_state{ $PROP_MAP{$prop} },
                        $value, undef );
                }

            }
        }

        $txn->{pre_state} = {%earlier_state};
    }

    return \%earlier_state, $final_state;
}

=head2 find_matching_transactions { ticket => $id, starting_transaction => $num  }

Returns a reference to an array of all transactions (as hashes) on ticket $id after transaction $num.

=cut

sub find_matching_transactions {
    my $self     = shift;
    my %args     = validate( @_, { ticket => 1, starting_transaction => 1 } );
    my @raw_txns = @{ $args{ticket}->comments };

    my @txns;
    for my $txn ( sort { $a->sequence <=> $b->sequence } @raw_txns ) {
        my $txn_date = $txn->date->epoch;

        # Skip things we know we've already pulled
        next if $txn_date < ( $args{'starting_transaction'} || 0 );

        # Skip things we've pushed
        next if (
            $self->sync_source->foreign_transaction_originated_locally(
                $txn_date, $args{'ticket'}->id
            )
          );

        # ok. it didn't originate locally. we might want to integrate it
        push @txns,
          {
            timestamp => $txn->date,
            serial    => $txn->sequence,
            object    => $txn,
          };
    }
    $self->sync_source->log('Done looking at pulled txns');

    return \@txns;
}

sub transcode_create_txn {
    my $self        = shift;
    my $txn         = shift;
    my $create_data = shift;
    my $final_data  = shift;
    my $ticket_id   = $final_data->{ $self->sync_source->uuid . '-id' };
    warn "recording create of "
      . $self->sync_source->uuid_for_remote_id($ticket_id);
    my $changeset = Prophet::ChangeSet->new(
        {
            original_source_uuid =>
              $self->sync_source->uuid_for_remote_id($ticket_id),
            original_sequence_no => 0,
            creator              => $self->resolve_user_id_to(
                email_address => $create_data->{reporter}
            ),
            created => $final_data->{created},
        }
    );

    my $change = Prophet::Change->new(
        {
            record_type => 'ticket',
            record_uuid => $self->sync_source->uuid_for_remote_id($ticket_id),
            change_type => 'add_file',
        }
    );

    for my $prop ( keys %{ $txn->{post_state} } ) {
        $change->add_prop_change(
            name => $prop,
            new  => ref( $txn->{post_state}->{$prop} ) eq 'ARRAY'
            ? join( ', ', @{ $txn->{post_state}->{$prop} } )
            : $txn->{post_state}->{$prop},
        );
    }
    $changeset->add_change( { change => $change } );
    return $changeset;
}

# we might get return:
# 0 changesets if it was a null txn
# 1 changeset if it was a normal txn
# 2 changesets if we needed to to some magic fixups.

sub transcode_one_txn {
    my $self               = shift;
    my $txn_wrapper        = shift;
    my $older_ticket_state = shift;
    my $newer_ticket_state = shift;

    my $txn = $txn_wrapper->{object};
    if ( $txn_wrapper->{serial} == 0 ) {
        return $self->transcode_create_txn( $txn_wrapper, $older_ticket_state,
            $newer_ticket_state );
    }

    my $ticket_id   = $newer_ticket_state->{ $self->sync_source->uuid . '-id' };
    my $ticket_uuid =
      $self->sync_source->uuid_for_remote_id( $ticket_id );
    warn "Recording an update to " . $ticket_uuid;
    my $changeset = Prophet::ChangeSet->new(
        {
            original_source_uuid => $ticket_uuid,
            original_sequence_no => $txn->sequence,
            creator =>
              $self->resolve_user_id_to( email_address => $txn->author ),
            created => $txn->date->ymd . " " . $txn->date->hms
        }
    );

    my $change = Prophet::Change->new(
        {
            record_type => 'ticket',
            record_uuid => $ticket_uuid,
            change_type => 'update_file'
        }
    );

    for my $prop ( keys %{ $txn_wrapper->{post_state} } ) {
        my $new = $txn_wrapper->{post_state}->{$prop};
        my $old = $txn_wrapper->{pre_state}->{$prop};
        $change->add_prop_change(
            name => $prop,
            new  => $new,
            old  => $old,
        ) unless $new eq $old;
    }

#    warn "right here, we need to deal with changed data that gcode failed to record";
    my %updates = %{ $txn->updates };

    my $props = $txn->updates;
    foreach my $prop ( keys %{ $props || {} } ) {
        $change->add_prop_change(
            name => $PROP_MAP{$prop},
            old  => $txn_wrapper->{pre_state}->{$PROP_MAP{$prop}},
            new  => $txn_wrapper->{post_state}->{$PROP_MAP{$prop}}
        );

    }

    $changeset->add_change( { change => $change } )
      if $change->has_prop_changes;

    $self->_include_change_comment( $changeset, $ticket_uuid, $txn );

    return unless $changeset->has_changes;
    return $changeset;
}

sub _include_change_comment {
    my $self        = shift;
    my $changeset   = shift;
    my $ticket_uuid = shift;
    my $txn         = shift;

    my $comment = Prophet::Change->new(
        {
            record_type => 'comment',
            record_uuid => Data::UUID->new->create_str()
            ,    # comments are never edited, we can have a random uuid
            change_type => 'add_file'
        }
    );

    if ( my $content = $txn->content ) {
        if ( $content !~ /^\s*$/s ) {
            $comment->add_prop_change(
                name => 'created',
                new  => $txn->date->ymd . ' ' . $txn->date->hms,
            );
            $comment->add_prop_change(
                name => 'creator',
                new =>
                  $self->resolve_user_id_to( email_address => $txn->author ),
            );
            $comment->add_prop_change( name => 'content', new => $content );
            $comment->add_prop_change(
                name => 'content_type',
                new  => 'text/plain',
            );
            $comment->add_prop_change( name => 'ticket', new => $ticket_uuid, );

            $changeset->add_change( { change => $comment } );
        }
    }
}

sub _recode_attachment_create {
    my $self = shift;
    my %args =
      validate( @_,
        { ticket => 1, txn => 1, changeset => 1, attachment => 1 } );
    my $change = Prophet::Change->new(
        {
            record_type => 'attachment',
            record_uuid => $self->sync_source->uuid_for_url(
                    $self->sync_source->remote_url
                  . "/attachment/"
                  . $args{'attachment'}->{'id'}
            ),
            change_type => 'add_file'
        }
    );
    $change->add_prop_change(
        name => 'content_type',
        old  => undef,
        new  => $args{'attachment'}->{'ContentType'}
    );
    $change->add_prop_change(
        name => 'created',
        old  => undef,
        new  => $args{'txn'}->{'Created'}
    );
    $change->add_prop_change(
        name => 'creator',
        old  => undef,
        new  => $self->resolve_user_id_to(
            email_address => $args{'attachment'}->{'Creator'}
        )
    );
    $change->add_prop_change(
        name => 'content',
        old  => undef,
        new  => $args{'attachment'}->{'Content'}
    );
    $change->add_prop_change(
        name => 'name',
        old  => undef,
        new  => $args{'attachment'}->{'Filename'}
    );
    $change->add_prop_change(
        name => 'ticket',
        old  => undef,
        new => $self->sync_source->uuid_for_remote_id( $args{'ticket'}->{'id'} )
    );
    $args{'changeset'}->add_change( { change => $change } );
}

sub translate_prop_status {
    my $self   = shift;
    my $status = shift;
    return lc($status);
}

sub resolve_user_id_to {
    my $self = shift;
    my $to   = shift;
    my $id   = shift;
    return $id . '@gmail.com';

}

__PACKAGE__->meta->make_immutable;
no Any::Moose;
1;
