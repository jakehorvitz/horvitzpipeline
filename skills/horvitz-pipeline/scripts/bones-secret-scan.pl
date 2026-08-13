#!/usr/bin/env perl
use strict;
use warnings;
use Digest::SHA qw(sha256_hex);
use File::Find qw(find);
use File::Spec;

my ($root, $allowlist) = @ARGV;
die "usage: bones-secret-scan.pl <source-dir> <allowlist>\n"
  unless defined $root && -d $root && defined $allowlist && -f $allowlist;

my %allowed;
open my $allow_fh, '<', $allowlist or die "cannot read $allowlist: $!\n";
while (my $line = <$allow_fh>) {
  chomp $line;
  $line =~ s/\r$//;
  next if $line =~ /^\s*(?:#|$)/;
  my ($digest, $rule, $path, $extra) = split /\t/, $line, 4;
  die "invalid allowlist row (expected sha256<TAB>rule<TAB>relative-path): $line\n"
    unless defined $digest && $digest =~ /^[a-f0-9]{64}$/
      && defined $rule && $rule =~ /^[A-Z0-9_-]+$/
      && defined $path && length($path) && !defined($extra);
  $allowed{"$digest\t$rule\t$path"} = 1;
}
close $allow_fh;

my @findings;
my @rules = (
  [ 'AWS_ACCESS_KEY_ID', qr/\b(?:AKIA|ASIA)[0-9A-Z]{16}\b/ ],
  [ 'GITHUB_TOKEN', qr/\bgh[opsu]_[A-Za-z0-9]{30,255}\b/ ],
  [ 'SLACK_TOKEN', qr/\bxox[baprs]-[A-Za-z0-9-]{10,}\b/ ],
  [ 'OPENAI_API_KEY', qr/\bsk-(?:proj-)?[A-Za-z0-9_-]{20,}\b/ ],
  [ 'PRIVATE_KEY', qr/-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----/ ],
);

sub entropy {
  my ($value) = @_;
  my %count;
  $count{$_}++ for split //, $value;
  my $length = length $value;
  my $result = 0;
  for my $n (values %count) {
    my $p = $n / $length;
    $result -= $p * (log($p) / log(2));
  }
  return $result;
}

sub record_finding {
  my ($path, $line, $rule, $secret) = @_;
  my $digest = sha256_hex($secret);
  return if $rule ne 'FORBIDDEN_PRIVATE_PATH'
    && $allowed{"$digest\t$rule\t$path"};
  push @findings, [$path, $line, $rule, $digest];
}

find({
  no_chdir => 1,
  preprocess => sub {
    return grep { $_ ne '.git' && $_ ne '.bones' && $_ ne 'node_modules' && $_ ne 'vendor' } @_;
  },
  wanted => sub {
    return unless -f $_ && !-l $_;
    my $relative = File::Spec->abs2rel($File::Find::name, $root);
    $relative =~ s{\\}{/}g;

    if ($relative =~ m{(?:^|/)(?:\.env(?:\..*)?|[^/]+\.env|memory(?:\.[^/]*)?|[^/]*voice[-_ ]?fingerprint[^/]*|[^/]*jarvis[-_ ]?voice[^/]*|[^/]*jakevoice[^/]*|[^/]*trivia[^/]*|[^/]*score[-_ ]?a[-_ ]?score[^/]*|[^/]*shavit[^/]*|[^/]*client[-_ ]?(?:data|material)[^/]*|[^/]*local[-_ ]?project[-_ ]?data[^/]*)$}i) {
      record_finding($relative, 0, 'FORBIDDEN_PRIVATE_PATH', $relative);
    }

    open my $fh, '<:raw', $File::Find::name or do {
      push @findings, [$relative, 0, 'UNREADABLE_FILE', sha256_hex($relative)];
      return;
    };
    local $/;
    my $contents = <$fh>;
    close $fh;
    return if !defined($contents) || $contents =~ /\x00/;

    my $line_no = 0;
    for my $line (split /\n/, $contents, -1) {
      ++$line_no;
      for my $entry (@rules) {
        my ($rule, $pattern) = @$entry;
        while ($line =~ /($pattern)/g) {
          record_finding($relative, $line_no, $rule, $1);
        }
      }
      while ($line =~ /(?<![A-Za-z0-9+\/_=-])([A-Za-z0-9+\/_=-]{24,})(?![A-Za-z0-9+\/_=-])/g) {
        my $token = $1;
        next unless $token =~ /[A-Z]/ && $token =~ /[a-z]/ && $token =~ /[0-9]/;
        record_finding($relative, $line_no, 'HIGH_ENTROPY', $token)
          if entropy($token) >= 4.5;
      }
    }
  },
}, $root);

if (@findings) {
  for my $finding (@findings) {
    my ($path, $line, $rule, $digest) = @$finding;
    print STDERR "bones package: BLOCKED bones-entropy $path:$line rule=$rule fingerprint=$digest\n";
  }
  exit 1;
}

print "bones package: bones-entropy clean\n";
exit 0;
