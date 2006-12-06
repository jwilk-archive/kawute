use strict;
use warnings;

package kawute;

use Getopt::Long qw(:config gnu_getopt no_ignore_case);
use Pod::Usage qw(pod2usage);

sub software_name($) { 'kawute'; }

our $timeout = 30;
sub timeout($;$)
{
  my ($this, $timeout) = @_;
  return $kawute::timeout unless defined $timeout;
  $kawute::timeout = $timeout;
}

our $debug = 0;
sub debug($;$)
{
  my ($this, $value) = @_;
  return $kawute::debug unless defined $value;
  $kawute::debug = $value;
}

our $use_bell = 0;
sub use_bell($;$)
{
  my ($this, $value) = @_;
  return $kawute::use_bell unless defined $value;
  $kawute::use_bell = $value;
}

our $person2number;
sub person2number($;$)
{
  my ($this, $value) = @_;
  return $kawute::person2number unless defined $value;
  $kawute::person2number = $value;
}

our $number2person;
sub number2person($;$)
{
  my ($this, $value) = @_;
  return $kawute::number2person unless defined $value;
  $kawute::number2person = $value;
}

our $reject_unpersons = 0;
sub reject_unpersons($;$)
{
  my ($this, $value) = @_;
  return $kawute::reject_unpersons unless defined $value;
  $kawute::reject_unpersons = $value;
}

our $account = our $account0 = 'default';
sub account($;$)
{
  my ($this, $value) = @_;
  return $kawute::account unless defined $value;
  $kawute::account = $value;
}

sub default_account($)
{
  return $kawute::account0;
}

our $force = 0;
sub force($;$)
{
  my ($this, $value) = @_;
  return $kawute::force unless defined $value;
  $kawute::force = $value;
}

sub error($$$)
{
  my ($this, $message, $code) = @_;
  $message .= " ($code)" if $this->debug();
  $this->quit($message);
}

sub api_error($$)
{
  my ($this, $message) = @_;
  $this->error('API error', "code: $message"); 
}

sub http_error($$)
{
  my ($this, $message) = @_;
  $this->error('HTTP error', $message);
}

sub debug_print($$)
{
  my ($this, $message) = @_;
  print STDERR "$message\n" if $this->debug();
};

sub quit($;$)
{
  my ($this, $message) = @_;
  print STDERR "\a" if $this->use_bell();
  print STDERR "$message\n" if defined $message;
  exit 1; 
}

sub cookie_domain($)
{
  return '!.invalid';
}

our $ua;
sub lwp_init($)
{
  require LWP::UserAgent;
  require HTTP::Cookies;
  my ($this) = @_;
  my $ua = new LWP::UserAgent();
  $ua->timeout($this->timeout());
  $ua->agent('Mozilla/5.0');
  $ua->env_proxy();
  $ua->cookie_jar(new HTTP::Cookies(file => './cookie-jar.txt', autosave => 1, ignore_discard => 1));
  my $account0 = $this->default_account();
  $ua->cookie_jar->scan(
    sub
    {
      my ($version, $key, $val, $path, $domain) = @_;
      $account0 = $val if $domain eq $this->fake_domain() and $key eq 'account';
    }
  );
  $ua->cookie_jar->clear($this->cookie_domain()) if $this->account() ne $account0;
  $ua->cookie_jar->set_cookie(0, 'account', $this->account(), '/', $this->fake_domain(), undef, undef, undef, 1 << 25, undef);
  $kawute::ua = $ua;
  return $ua;
}

sub lwp_get($$)
{
  require HTTP::Request;
  my ($this, $uri) = @_;
  return new HTTP::Request(GET => $uri);
}

sub lwp_post($$;$)
{
  require HTTP::Request::Common;
  my ($this, $uri, $values) = @_;
  return HTTP::Request::Common::POST($uri, $values);
}

sub lwp_visit($$$)
{
  my ($this, $ua, $uri) = @_;
  my $res = $ua->request($this->lwp_get($uri));
  $this->http_error($uri) unless $res->is_success;
  return $res;
}

sub expand_tilde($$)
{
  (my $this, $_) = @_;
  s{^~([^/]*)}{length $1 > 0 ? (getpwnam($1))[7] : ( $ENV{'HOME'} || $ENV{'LOGDIR'} )}e;
  return $_;
}

sub transliterate($$)
{
  require Text::Unidecode;
  my ($this, $text) = @_;
  Text::Unidecode::unidecode($text);
  return $text;
}

sub codeset($)
{
  require I18N::Langinfo; import I18N::Langinfo qw(langinfo CODESET);
  my $codeset = langinfo(CODESET()) or die;
  return $codeset;
}

sub resolve_number($$)
{
  my ($this, $number) = @_;
  if (defined $this->number2person())
  {
    open N2P, '-|:encoding(utf-8)', $this->number2person(), $number or $this->quit(q(Can't invoke resolver));
    $_ = <N2P>;
    close N2P;
    my ($person) = split /\t/ if defined $_;
    return "$person <$number>" if defined $person;
  }
  return undef if $this->reject_unpersons();
  return "<$number>";
}

sub resolve_person($$)
{
  my ($this, $number, $recipient);
  ($this, $recipient) = @_;
  if ($recipient =~ /[^+\d]/ and defined $this->person2number())
  {
    open P2N, '-|:encoding(utf-8)', $this->person2number(), $recipient or $this->quit(q(Can't invoke resolver));
    my @phonebook = <P2N>;
    close P2N;
    if ($#phonebook == 0)
    {
      ($_, $number) = split /\t/, $phonebook[0];
    }
    elsif ($#phonebook > 0)
    {
      print STDERR "Ambiguous recipient, please make up your mind:\n";
      print STDERR "  $_" foreach @phonebook;
      $this->quit();
    }
    else
    {
      $number = '';
    }
  }
  else
  {
    $number = $recipient;
  }
  $number = $this->fix_number($number);
  $recipient = $this->resolve_number($number);
  $this->quit('No such recipient') unless defined $recipient;
  return ($number, $recipient);
}

sub read_config($%)
{
  require Apache::ConfigFile;
  my ($this, %conf_vars) = @_;
  my %default_conf_vars =
  (
    'number2person' => sub 
      { $this->number2person($this->expand_tilde(shift)); },
    'person2number' => sub 
      { $this->person2number($this->expand_tilde(shift)); },
    'rejectunpersons' => sub 
      { $this->reject_unpersons(shift); },
    'debug' => sub 
      { $this->debug(shift); },
    'usebell' => sub 
      { $this->use_bell(shift); },
    'timeout' => sub
      { $this->timeout(shift); }
  );
  foreach (keys %default_conf_vars)
  {
    $conf_vars{$_} = $default_conf_vars{$_} unless exists $conf_vars{$_};
  }
  my $ac = Apache::ConfigFile->read(file => $this->config_file(), ignore_case => 1, fix_booleans => 1, raise_error => 1);
  foreach my $context (($ac, scalar $ac->cmd_context(site => $this->site())))
  {
    next unless $context =~ /\D/;
    foreach my $subcontext ($context, $context->cmd_context(account => $this->account()))
    {
      next unless $subcontext =~ /\D/;
      foreach my $var (keys %conf_vars)
      {
        my $val = $subcontext->cmd_config($var);
        $conf_vars{$var}($val) if defined $val;
      }
    }
  }
}

sub get_options($@)
{
  my ($this, %options) = @_;
  my %default_options =
  (
    'force' => sub 
      { $this->force(1); },
    'version' => sub 
      { $this->quit($this->software_name() . "version " . $this->version()); },
    'debug' => sub 
      { $this->debug(1); },
    'help|h|?' =>  sub 
      { pod2usage(1); },
    'account=s' => sub 
      { 
        ($_, my $account) = @_;
        $this->account($account); 
      }
  );
  foreach (keys %default_options)
  {
    $options{$_} = $default_options{$_} unless exists $options{$_};
  }
  GetOptions(%options) or pod2usage(1);
}

sub go_home($)
{
  my ($this) = @_;
  my $env = my $software_name = $this->software_name();
  $env =~ s/\W//g;
  $env =~ y/a-z/A-Z/;
  $env .= '_HOME';
  my $home = exists $ENV{$env} ? $ENV{$env} : "$ENV{'HOME'}/.$software_name/";
  chdir $home or $this->quit("Can't change working directory to $home");
}

sub fake_domain($)
{
  my ($this) = @_;
  return $this->site() . '.invalid';
}

sub action_logout($)
{
  my ($this) = @_;
  $ua = $this->lwp_init() unless defined $ua;
  $ua->cookie_jar->clear($this->cookie_domain());
  debug 'Cookies has been purged';
  exit;
}

sub action_void($)
{
  exit;
}

1;

__END__

vim:ts=2 sw=2 et
