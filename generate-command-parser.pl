#!/usr/bin/env perl
# vim:ts=4:sw=4:expandtab
#
# i3 - an improved dynamic tiling window manager
# © 2009-2012 Michael Stapelberg and contributors (see also: LICENSE)
#
# generate-command-parser.pl: script to generate parts of the command parser
# from its specification file parser-specs/commands.spec.
#
# Requires only perl >= 5.10, no modules.

use strict;
use warnings;
use Data::Dumper;
use v5.10;

# reads in a whole file
sub slurp {
    open my $fh, '<', shift;
    local $/;
    <$fh>;
}

# Stores the different states.
my %states;

# XXX: don’t hardcode input and output
my $input = '../parser-specs/commands.spec';
my @raw_lines = split("\n", slurp($input));
my @lines;

# XXX: In the future, we might switch to a different way of parsing this. The
# parser is in many ways not good — one obvious one is that it is hand-crafted
# without a good reason, also it preprocesses lines and forgets about line
# numbers. Luckily, this is just an implementation detail and the specification
# for the i3 command parser is in-tree (not user input).
# -- michael, 2012-01-12

# First step of preprocessing:
# Join token definitions which are spread over multiple lines.
for my $line (@raw_lines) {
    next if $line =~ /^\s*#/ || $line =~ /^\s*$/;

    if ($line =~ /^\s+->/) {
        # This is a continued token definition, append this line to the
        # previous one.
        $lines[$#lines] = $lines[$#lines] . $line;
    } else {
        push @lines, $line;
        next;
    }
}

# First step: We build up the data structure containing all states and their
# token rules.

my $current_state;

for my $line (@lines) {
    if (my ($state) = ($line =~ /^state ([A-Z_]+):$/)) {
        #say "got a new state: $state";
        $current_state = $state;
    } else {
        # Must be a token definition:
        # [identifier = ] <tokens> -> <action>
        #say "token definition: $line";

        my ($identifier, $tokens, $action) =
            ($line =~ /
                ^\s*                  # skip leading whitespace
                ([a-z_]+ \s* = \s*|)  # optional identifier
                (.*?) -> \s*          # token 
                (.*)                  # optional action
             /x);

        # Cleanup the identifier (if any).
        $identifier =~ s/^\s*(\S+)\s*=\s*$/$1/g;

        # Cleanup the tokens (remove whitespace).
        $tokens =~ s/\s*//g;

        # The default action is to stay in the current state.
        $action = $current_state if length($action) == 0;

        #say "identifier = *$identifier*, token = *$tokens*, action = *$action*";
        for my $token (split(',', $tokens)) {
            my $store_token = {
                token => $token,
                identifier => $identifier,
                next_state => $action,
            };
            if (exists $states{$current_state}) {
                push @{$states{$current_state}}, $store_token;
            } else {
                $states{$current_state} = [ $store_token ];
            }
        }
    }
}

# Second step: Generate the enum values for all states.

# It is important to keep the order the same, so we store the keys once.
my @keys = keys %states;

open(my $enumfh, '>', 'GENERATED_enums.h');

# XXX: we might want to have a way to do this without a trailing comma, but gcc
# seems to eat it.
say $enumfh 'typedef enum {';
my $cnt = 0;
for my $state (@keys, '__CALL') {
    say $enumfh "    $state = $cnt,";
    $cnt++;
}
say $enumfh '} cmdp_state;';
close($enumfh);

# Third step: Generate the call function.
open(my $callfh, '>', 'GENERATED_call.h');
say $callfh 'static void GENERATED_call(const int call_identifier, struct CommandResult *result) {';
say $callfh '    switch (call_identifier) {';
my $call_id = 0;
for my $state (@keys) {
    my $tokens = $states{$state};
    for my $token (@$tokens) {
        next unless $token->{next_state} =~ /^call /;
        my ($cmd) = ($token->{next_state} =~ /^call (.*)/);
        my ($next_state) = ($cmd =~ /; ([A-Z_]+)$/);
        $cmd =~ s/; ([A-Z_]+)$//;
        # Go back to the INITIAL state unless told otherwise.
        $next_state ||= 'INITIAL';
        my $fmt = $cmd;
        # Replace the references to identified literals (like $workspace) with
        # calls to get_string().
        $cmd =~ s/\$([a-z_]+)/get_string("$1")/g;
        # Used only for debugging/testing.
        $fmt =~ s/\$([a-z_]+)/%s/g;
        $fmt =~ s/"([a-z0-9_]+)"/%s/g;

        say $callfh "         case $call_id:";
        say $callfh '#ifndef TEST_PARSER';
        my $real_cmd = $cmd;
        if ($real_cmd =~ /\(\)/) {
            $real_cmd =~ s/\(/(&current_match, result/;
        } else {
            $real_cmd =~ s/\(/(&current_match, result, /;
        }
        say $callfh "             $real_cmd;";
        say $callfh '#else';
        # debug
        $cmd =~ s/[^(]+\(//;
        $cmd =~ s/\)$//;
        $cmd = ", $cmd" if length($cmd) > 0;
        say $callfh qq|           printf("$fmt\\n"$cmd);|;
        say $callfh '#endif';
        say $callfh "             state = $next_state;";
        say $callfh "             break;";
        $token->{next_state} = "call $call_id";
        $call_id++;
    }
}
say $callfh '        default:';
say $callfh '            printf("BUG in the parser. state = %d\n", call_identifier);';
say $callfh '    }';
say $callfh '}';
close($callfh);

# Fourth step: Generate the token datastructures.

open(my $tokfh, '>', 'GENERATED_tokens.h');

for my $state (@keys) {
    my $tokens = $states{$state};
    say $tokfh 'cmdp_token tokens_' . $state . '[' . scalar @$tokens . '] = {';
    for my $token (@$tokens) {
        my $call_identifier = 0;
        my $token_name = $token->{token};
        if ($token_name =~ /^'/) {
            # To make the C code simpler, we leave out the trailing single
            # quote of the literal. We can do strdup(literal + 1); then :).
            $token_name =~ s/'$//;
        }
        my $next_state = $token->{next_state};
        if ($next_state =~ /^call /) {
            ($call_identifier) = ($next_state =~ /^call ([0-9]+)$/);
            $next_state = '__CALL';
        }
        my $identifier = $token->{identifier};
        say $tokfh qq|    { "$token_name", "$identifier", $next_state, { $call_identifier } }, |;
    }
    say $tokfh '};';
}

say $tokfh 'cmdp_token_ptr tokens[' . scalar @keys . '] = {';
for my $state (@keys) {
    my $tokens = $states{$state};
    say $tokfh '    { tokens_' . $state . ', ' . scalar @$tokens . ' },';
}
say $tokfh '};';

close($tokfh);