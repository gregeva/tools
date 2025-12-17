use strict;
use warnings;
use Text::CSV;
use Time::Piece;

# Initialize CSV
my $csv = Text::CSV->new({ binary => 1, eol => $/ });
open my $fh, '>', 'output.csv' or die "Could not open output.csv: $!";
$csv->print($fh, ['serverTimestamp', 'propertyTimestamp', 'thingName', 'property', 'quality', 'hasChanged', 'value']);

# Initialize data structure
my %data;
my $lines = 0;

# Read log file
open my $log, '<', 'PropertyUpdates.log' or die "Could not open log file: $!";
while (my $line = <$log>) {
    # if ($line =~ /(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}\+\d{4}) .* For a thing named '(?<thing>.+)' and property named '(?<property>.*)?', updated property value is (?<value>.*)/) {
    # print "Processing line: $line" if $lines++ < 5;
    # "2025-12-12 15:59:38.006+0100";"";"AI_IOLINK_Pression_Eau_Urgence";"1765551575383";"5195";"GOOD"
    # "2025-12-12 15:59:38.006+0100";"";"AI_Pyrometre";"1765551576856";"1.5227141380310059";"GOOD"
    # "2025-12-12 15:59:38.006+0100";"";"AI_Vide_chambre";"1765551576858";"1.73614501953125";"GOOD"
    if ($line =~ /"(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}\+\d{4})";"(?<thing>.*)";"(?<property>.*)";"(?<timestamp>.*)";"(?<value>.*)";"(?<quality>.*)"/) {
        my $serverTimestamp = $1;
        my $propertyTimestampMs = $+{timestamp};
        my $propertyTimestamp;
        my $thing = $+{thing};
        my $property = $+{property};
        my $value = $+{value};
        my $quality = $+{quality};
        my $hasChanged = 1;

        chop $value;

        # Convert milliseconds since epoch to human-readable timestamp using Time::Piece
        if (defined $propertyTimestampMs && $propertyTimestampMs =~ /^\d+$/) {
            my $t_sec = int($propertyTimestampMs / 1000);
            my $ms = $propertyTimestampMs % 1000;
            my $tp = Time::Piece->localtime($t_sec);
            $propertyTimestamp = $tp->strftime("%Y-%m-%d %H:%M:%S") . sprintf(".%03d", $ms) . $tp->strftime("%z");
        }

        # Check if value has changed
# print "Extracted - Timestamp: $timestampMs, Thing: $thing, Property: $property, Value: $value, Quality: $quality\n" if $lines <= 5;

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

        # Write to CSV (leave CSV columns unchanged; keep original timestamp milliseconds)
        $csv->print($fh, [$serverTimestamp, $propertyTimestamp, $thing, $property, $quality, $hasChanged, $value]);
    }
}
close $log;
close $fh;

print "Processing complete. Output saved to output.csv\n";

