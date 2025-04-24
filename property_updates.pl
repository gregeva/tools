use strict;
use warnings;
use Text::CSV;
use Time::Piece;

# Initialize CSV
my $csv = Text::CSV->new({ binary => 1, eol => $/ });
open my $fh, '>', 'output.csv' or die "Could not open output.csv: $!";
$csv->print($fh, ['timestamp', 'thing', 'property', 'value', 'hasChanged']);

# Initialize data structure
my %data;
my $lines = 0;

# Read log file
open my $log, '<', 'PropertyUpdates.log' or die "Could not open log file: $!";
while (my $line = <$log>) {
    if ($line =~ /(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}\+\d{4}) .* For a thing named '(?<thing>.+)' and property named '(?<property>.*)?', updated property value is (?<value>.*)/) {
        my $timestamp = $1;
        my $thing = $+{thing};
        my $property = $+{property};
        my $value = $+{value};
        my $hasChanged = 1;

        chop $value;
        # Check if value has changed

        if( exists $data{$thing}{$property} && $data{$thing}{$property} eq $value ) {
		$hasChanged = 0;
        } elsif( exists $data{$thing}{$property} && $data{$thing}{$property} ne $value ) {
                $hasChanged = 1;
        } elsif( !exists $data{$thing}{$property} ) {
                $hasChanged = 1;
        }

	#print "$thing $property |$hasChanged| oldValue: " . ( defined $data{$thing}{$property} ? $data{$thing}{$property} : "N/A" ) . " newValue: $value\n" if length( $value ) < 10;
        #last if $lines++ > 20;

        # Update data structure
        $data{$thing}{$property} = $value;

        # Write to CSV
        $csv->print($fh, [$timestamp, $thing, $property, $value, $hasChanged]);
    }
}
close $log;
close $fh;

print "Processing complete. Output saved to output.csv\n";

