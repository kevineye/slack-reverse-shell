#!/usr/bin/perl
use strict;

my $token = shift;; # see https://api.slack.com/web#authentication to generate a token
my $group = lookup_group($token, shift);

die <<USAGE unless $token and $group;
usage: $0 <slack token> <private group name>
See https://api.slack.com/web#authentication to generate a token.
USAGE

my $host = `hostname`;
$host =~ s{\..*}{};
my $oldest = time;

system 'curl', '-fSs', '-o', '/dev/null', '-F', "username=$host", '-F', "token=$token", '-F', "channel=$group", '-F', "text=Hello!", 'https://slack.com/api/chat.postMessage' and die $!;

while(1) {
    my $res = qx{curl -fSs 'https://slack.com/api/groups.history?token=$token&channel=$group&oldest=$oldest'};
    die $! unless $res;
    my $data = decode_json($res);
    die $res unless $data->{ok};
    for my $message (@{$data->{messages}}) {
        $oldest = $message->{ts};
        if ($message->{type} eq "message" and !$message->{subtype}) {
            my $cmd = $message->{text};
            $cmd =~ s{\N{U+2018}|\N{U+2019}}{'}g; # slack client automatically curls quotes; undo that
            $cmd =~ s{\N{U+201C}|\N{U+201D}}{"}g; # slack client automatically curls quotes; undo that
            $cmd =~ s{\N{U+2014}}{--}g; # slack client automatically converts -- to em dash; undo that
            $cmd =~ s{<([^>]+)>}{$1}g; # slack client automatically hyperlinks url-ish things; undo that
            $cmd =~ s{&lt;}{<}g; # unescape standard chars
            $cmd =~ s{&gt;}{>}g; # unescape standard chars
            $cmd =~ s{&amp;}{&}g; # unescape standard chars
            bye() if $cmd =~ m{^\s*(exit|bye|quit|die)\s*$}i; # say any of these things to kill the shell
            my $out = qx{$cmd 2>&1}; # run, redirecting stderr to stdout
            system 'curl', '-fSs', '-o', '/dev/null', '-F', 'parse=none', '-F', "username=$host", '-F', "token=$token", '-F', "channel=$group", '-F', "text=$cmd", '-F', 'attachments='.encode_json([{text => $out, color => ${^CHILD_ERROR_NATIVE} ? 'danger' : 'good'}]), 'https://slack.com/api/chat.postMessage' and die $!;
        }
    }
}

sub bye {
    system 'curl', '-fSs', '-o', '/dev/null', '-F', "username=$host", '-F', "token=$token", '-F', "channel=$group", '-F', "text=Goodbye.", 'https://slack.com/api/chat.postMessage' and die $!;
    exit;
}

sub lookup_group {
    my ($token, $group_name) = @_;
    return unless $token and $group_name;
    my $group_res = qx{curl -fSs 'https://slack.com/api/groups.list?token=$token'};
    die $! unless $group_res;
    my $groups = decode_json($group_res);
    die $group_res unless $groups->{ok};
    $_->{name} eq $group_name and return $_->{id} for @{$groups->{groups}};
    return;
}


# from Mojo::JSON

my %ESCAPE;
my %REVERSE;
BEGIN {
    %ESCAPE = (
      '"'     => '"',
      '\\'    => '\\',
      '/'     => '/',
      'b'     => "\x08",
      'f'     => "\x0c",
      'n'     => "\x0a",
      'r'     => "\x0d",
      't'     => "\x09",
      'u2028' => "\x{2028}",
      'u2029' => "\x{2029}"
    );
    %REVERSE = map { $ESCAPE{$_} => "\\$_" } keys %ESCAPE;
    for (0x00 .. 0x1f) { $REVERSE{pack 'C', $_} //= sprintf '\u%.4X', $_ }
}

sub false () { undef }
sub true () { 1 }

sub decode_json {
  my $err = _decode(\my $value, shift);
  return defined $err ? croak $err : $value;
}

sub _decode {
  my $valueref = shift;

  eval {

    # Missing input
    die "Missing or empty input\n" if (local $_ = shift) eq '';

    # Value
    $$valueref = _decode_value();

    # Leftover data
    /\G[\x20\x09\x0a\x0d]*\z/gc or die('Unexpected data');
  } ? return undef : chomp $@;

  return $@;
}

sub _decode_array {
  my @array;
  until (m/\G[\x20\x09\x0a\x0d]*\]/gc) {

    # Value
    push @array, _decode_value();

    # Separator
    redo if /\G[\x20\x09\x0a\x0d]*,/gc;

    # End
    last if /\G[\x20\x09\x0a\x0d]*\]/gc;

    # Invalid character
    die('Expected comma or right square bracket while parsing array');
  }

  return \@array;
}

sub _decode_object {
  my %hash;
  until (m/\G[\x20\x09\x0a\x0d]*\}/gc) {

    # Quote
    /\G[\x20\x09\x0a\x0d]*"/gc
      or die('Expected string while parsing object');

    # Key
    my $key = _decode_string();

    # Colon
    /\G[\x20\x09\x0a\x0d]*:/gc or die('Expected colon while parsing object');

    # Value
    $hash{$key} = _decode_value();

    # Separator
    redo if /\G[\x20\x09\x0a\x0d]*,/gc;

    # End
    last if /\G[\x20\x09\x0a\x0d]*\}/gc;

    # Invalid character
    die('Expected comma or right curly bracket while parsing object');
  }

  return \%hash;
}

sub _decode_string {
  my $pos = pos;

  # Extract string with escaped characters
  m!\G((?:(?:[^\x00-\x1f\\"]|\\(?:["\\/bfnrt]|u[0-9a-fA-F]{4})){0,32766})*)!gc;
  my $str = $1;

  # Invalid character
  unless (m/\G"/gc) {
    die('Unexpected character or invalid escape while parsing string')
      if /\G[\x00-\x1f\\]/;
    die('Unterminated string');
  }

  # Unescape popular characters
  if (index($str, '\\u') < 0) {
    $str =~ s!\\(["\\/bfnrt])!$ESCAPE{$1}!gs;
    return $str;
  }

  # Unescape everything else
  my $buffer = '';
  while ($str =~ /\G([^\\]*)\\(?:([^u])|u(.{4}))/gc) {
    $buffer .= $1;

    # Popular character
    if ($2) { $buffer .= $ESCAPE{$2} }

    # Escaped
    else {
      my $ord = hex $3;

      # Surrogate pair
      if (($ord & 0xf800) == 0xd800) {

        # High surrogate
        ($ord & 0xfc00) == 0xd800
          or pos = $pos + pos($str), die('Missing high-surrogate');

        # Low surrogate
        $str =~ /\G\\u([Dd][C-Fc-f]..)/gc
          or pos = $pos + pos($str), die('Missing low-surrogate');

        $ord = 0x10000 + ($ord - 0xd800) * 0x400 + (hex($1) - 0xdc00);
      }

      # Character
      $buffer .= pack 'U', $ord;
    }
  }

  # The rest
  return $buffer . substr $str, pos($str), length($str);
}

sub _decode_value {

  # Leading whitespace
  /\G[\x20\x09\x0a\x0d]*/gc;

  # String
  return _decode_string() if /\G"/gc;

  # Object
  return _decode_object() if /\G\{/gc;

  # Array
  return _decode_array() if /\G\[/gc;

  # Number
  return 0 + $1
    if /\G([-]?(?:0|[1-9][0-9]*)(?:\.[0-9]*)?(?:[eE][+-]?[0-9]+)?)/gc;

  # True
  return true() if /\Gtrue/gc;

  # False
  return false() if /\Gfalse/gc;

  # Null
  return undef if /\Gnull/gc;

  # Invalid character
  die('Expected string, array, object, number, boolean or null');
}

sub encode_json { _encode_value(shift) }

sub _encode_array {
  '[' . join(',', map { _encode_value($_) } @{$_[0]}) . ']';
}

sub _encode_object {
  my $object = shift;
  my @pairs = map { _encode_string($_) . ':' . _encode_value($object->{$_}) }
    keys %$object;
  return '{' . join(',', @pairs) . '}';
}

sub _encode_string {
  my $str = shift;
  $str =~ s!([\x00-\x1f\x{2028}\x{2029}\\"/])!$REVERSE{$1}!gs;
  return "\"$str\"";
}

sub _encode_value {
  my $value = shift;

  # Reference
  if (my $ref = ref $value) {

    # Object
    return _encode_object($value) if $ref eq 'HASH';

    # Array
    return _encode_array($value) if $ref eq 'ARRAY';

    # True or false
    return $$value ? 'true' : 'false' if $ref eq 'SCALAR';
    return $value  ? 'true' : 'false' if $ref eq 'JSON::PP::Boolean';

    # Blessed reference with TO_JSON method
    if (blessed $value && (my $sub = $value->can('TO_JSON'))) {
      return _encode_value($value->$sub);
    }
  }

  # Null
  return 'null' unless defined $value;

  # String
  return _encode_string($value);
}
