package App::SD::CLI::Command::Help;
use Moose;
extends 'Prophet::CLI::Command';
with 'App::SD::CLI::Command';

sub run {

print <<EOF
$0 @{[$App::SD::VERSION]}

$0 ticket create -- summary "This is a summary" status new somekey value
$0 ticket update --id <id> -- status closed
$0 ticket resolve --id <id>
$0 ticket search --regex .
$0 ticket search -- status!=closed summary =~ http 
$0 ticket delete --id <id>
$0 ticket show --id <id>
$0 ticket details --id <id>
$0 pull --from remote-url
$0 pull --all
$0 publish --to remote-url

$0 help
    Show this file

= ENVIRONMENT

  export SD_REPO=/path/to/sd/replica
  # Specify where the ticket database SD is using should reside

= EXAMPLES

    sd pull --from rt:http://rt3.fsck.com|QUEUENAME|QUERY

EOF

}

__PACKAGE__->meta->make_immutable;
no Moose;

1;

