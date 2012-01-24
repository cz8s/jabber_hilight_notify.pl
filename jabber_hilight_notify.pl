use Irssi;
use strict;
use Net::XMPP;
use vars qw($VERSION %IRSSI);

# FIXME/TODO
# - Implement real invisibility with Privacy Lists
# - Make SSL connection work
# - Handle jabber:iq:version
# - handle charsets better (possible? -- would mean to guess somehow)

$VERSION = "20061108";
%IRSSI = (
    authors     => 'David Ammouial <da|A|weeno|D|net>',
    name        => 'jabber_hilight_notify',
    description => 'Send hilight notifications to a jabber address',
    license     => 'GPL v2',
);


# Configure here the subject and the body of the message. For each of them,
# there are two situations:
#  - QUERY: In a private message
#  - CHANNEL: On a channel
# You can use the following variables:
# - $where: The channel or person you are talking with.
# - $text: The text that appeared on IRC
sub message_parts
{
    my ($where, $text) = @_;
    ###############################################
    my %SUBJECT = ( # The subject of the message
    	'QUERY'   =>   'private message',
	'CHANNEL' =>   'channel hilight',
    );
    my %BODY = ( # The content of the message
        'QUERY'   =>   "Private message from $where: $text",
        'CHANNEL' =>   "Message on $where: $text",
    );
    ###############################################
    return (\%SUBJECT, \%BODY);
}

## register config variables
Irssi::settings_add_str('jabber', 'jabber_id', '');
Irssi::settings_add_str('jabber', 'jabber_password', '');
Irssi::settings_add_str('jabber', 'jabber_server', '');
Irssi::settings_add_time('jabber', 'jabber_server_reconnect_time', 0);
Irssi::settings_add_bool('jabber', $IRSSI{'name'} . '_when_away', 'false');
Irssi::settings_add_str('jabber', $IRSSI{'name'} . '_target', '');
Irssi::settings_add_str('jabber', $IRSSI{'name'} . '_target_presence',
                        'online chat');

# Register formats
Irssi::theme_register([
    'jabber_notifier_crap' => '{line_start}{hilight ' . $IRSSI{'name'} . ':} $0'
]);

our $cnx;
our $i_spoke_last = 0;
our $send_notif = 0;
jabber_connect();

sub say
{
    Irssi::printformat(MSGLEVEL_CLIENTCRAP, 'jabber_notifier_crap', shift);
}	

# Update the $send_notif global var when receiving presence packets
sub trackPresence
{
    my ($sess, $presence) = @_;
    my $target = new Net::XMPP::JID(Irssi::settings_get_str($IRSSI{'name'} . '_target'));
    my $jid_match = $target->GetResource() eq '' ? 'base' : 'full';
    $target = $target->GetJID($jid_match);
    return if ($presence->GetFrom('jid')->GetJID($jid_match) != $target);
    my @listens = map(lc, split(' ',
            Irssi::settings_get_str($IRSSI{'name'} . '_target_presence')));
    my $keyword;
    if ($presence->GetType() eq 'unavailable') {
        $keyword = 'unavailable';
    } elsif ($presence->GetType() =~ /^(available)?$/) {
        ($keyword = $presence->GetShow()) =~ s/^$/online/;
    }
    $send_notif = grep(/^$keyword$/, @listens);
}

sub jabber_connect
{
    $cnx = new Net::XMPP::Client();
    $cnx->SetCallBacks(presence => \&trackPresence);
    my $jid_string = Irssi::settings_get_str('jabber_id');
    my $password = Irssi::settings_get_str('jabber_password');
    our $jid = new Net::XMPP::JID($jid_string);
    #$jid->SetJID($jid_string);
    $jid->SetResource('remote_irssi') unless $jid->GetResource();
    my $vhost = $jid->GetServer();
    my ($server, $port) = split(/:/, (Irssi::settings_get_str('jabber_server')
                                      || $vhost));
    $port = 5222 unless ($port);
    say("Connecting to $server:$port...");
    $cnx->Connect(hostname => $server, port => $port, componentname => $vhost);
    unless ($cnx->Connected()) {
	schedule_reconnect("Couldn't connect to $server:$port");
        return;
    }
    my @result = $cnx->AuthSend(username => $jid->GetUserID(),
                                password => $password,
                                resource => $jid->GetResource());
    say("Authentication result: @result");
    if ('ok' eq $result[0]) {
        $cnx->PresenceSend(priority => -1,
                           show => 'dnd',
                           status => 'I\'m not a real person, don\'t talk to me. I just don\'t know how to become invisible with Net::XMPP :p');
        set_timer();
    } else {
        $cnx->Disconnect();
	schedule_reconnect('Authentication failed');
    }
}

# Schedule a reconnection and display an informative message along the way.
sub schedule_reconnect
{
    my $message = shift;
    our $timer;
    Irssi::timeout_remove($timer);
    my $reconnect_time_setting = 'jabber_server_reconnect_time';
    if (0 == Irssi::settings_get_time($reconnect_time_setting)) {
        $reconnect_time_setting = 'server_reconnect_time';
    }
    my $reconnect_time = Irssi::settings_get_time($reconnect_time_setting);
    my $human_time = Irssi::settings_get_str($reconnect_time_setting);
    say("$message. Reconnecting in $human_time.");
    Irssi::timeout_add_once($reconnect_time => sub {
        say('Trying to reconnect...');
	jabber_connect();
    }, '');
    say("Scheduling planned in $human_time");
}

sub set_timer
{
    our $timer;
    Irssi::timeout_remove($timer) if defined($timer);
    $timer = Irssi::timeout_add(2000 => sub {
        schedule_reconnect('Lost connection') unless (defined($cnx->Process(0)));
    }, '');
}

sub sig_print_text {
    my ($dest, $text, $stripped) = @_;
    my $server = $dest->{server};
    my $witem = $dest->{window}->{active};
    return unless ($send_notif);
    return unless ($server);
    return unless ($dest->{level} & (MSGLEVEL_HILIGHT|MSGLEVEL_MSGS));
    my $ignored_level = MSGLEVEL_NOTICES|MSGLEVEL_SNOTES|MSGLEVEL_CTCPS|MSGLEVEL_JOINS|MSGLEVEL_PARTS|MSGLEVEL_QUITS|MSGLEVEL_KICKS|MSGLEVEL_MODES|MSGLEVEL_TOPICS|MSGLEVEL_WALLOPS|MSGLEVEL_INVITES|MSGLEVEL_NICKS|MSGLEVEL_DCC|MSGLEVEL_DCCMSGS|MSGLEVEL_CLIENTNOTICE|MSGLEVEL_CLIENTERROR;
    return if (($dest->{level} & $ignored_level));
    return if ($i_spoke_last);
    if (Irssi::settings_get_bool($IRSSI{'name'} . '_when_away')
        || !($server->{usermode_away})) {
        my $to = Irssi::settings_get_str($IRSSI{'name'} . '_target');
        return if ($to eq '');
	my ($subjects, $bodies) = message_parts($dest->{target}, $stripped);
        $cnx->MessageSend(to =>$to, subject => $subjects->{$witem->{type}},
	                  body => $bodies->{$witem->{type}});
    }
}

sub UNLOAD
{
    our $timer;
    Irssi::timeout_remove($timer) if defined($timer);
    say($IRSSI{'name'} . ' exiting.');
    return unless ($cnx->Connected());
    $cnx->PresenceSend(type => 'unavailable');
    $cnx->Disconnect();    
}

Irssi::signal_add_last('message private', sub { $i_spoke_last = 0;});
Irssi::signal_add_last('message own_private', sub { $i_spoke_last = 1;});
Irssi::signal_add_last('print text', 'sig_print_text');
