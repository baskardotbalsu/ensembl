package XrefParser::EntrezGeneParser;

use strict;
use POSIX qw(strftime);
use File::Basename;

use XrefParser::BaseParser;

use vars qw(@ISA);
@ISA = qw(XrefParser::BaseParser);


# --------------------------------------------------------------------------------
# Parse command line and run if being run directly

if (!defined(caller())) {

  if (scalar(@ARGV) != 1) {
    print "\nUsage: EntrezGeneParser.pm file <source_id> <species_id>\n\n";
    exit(1);
  }

  run($ARGV[0]);

}

sub run {

  my $self = shift if (defined(caller(1)));
  my $file = shift;
  my $source_id = shift;
  my $species_id = shift;

  if(!defined($source_id)){
    $source_id = XrefParser::BaseParser->get_source_id_for_filename($file);
  }
  if(!defined($species_id)){
    $species_id = XrefParser::BaseParser->get_species_id_for_filename($file);
  }
  
  my $species_tax_id = $self->get_taxonomy_from_species_id($species_id);
  

  if(!open(EG,"<".$file)){
    print  "ERROR: Could not open $file\n";
    return 1; # 1 is an error
  }

  

  my $head = <EG>; # first record are the headers
  chomp $head;
  my (@arr) = split(/\s+/,$head);
  # process this to the correct indexes to use. (incase they change);

  my $gene_id_index = -2;
  my $gene_symbol_index = -2;
  my $gene_desc_index = -2;
  my $gene_tax_id_index = -2;
  my $gene_synonyms_index = -2;
  foreach (my $i=0; $i<= $#arr; $i++){
    #-1 as first one is "#Format:"q
    if($arr[$i] eq "tax_id"){
      $gene_tax_id_index = $i-1;
    }
    elsif($arr[$i] eq "GeneID"){
      $gene_id_index = $i-1;
    }
    elsif($arr[$i] eq "Symbol"){
      $gene_symbol_index = $i-1;
    }
    elsif($arr[$i] eq "description"){
      $gene_desc_index = $i-1;
    }
    elsif($arr[$i] eq "Synonyms"){
      $gene_synonyms_index = $i-1;
    }
  }
  if( $gene_id_index       == -2 ||
      $gene_symbol_index   == -2 ||
      $gene_desc_index     == -2 ||
      $gene_synonyms_index == -2 ||
      $gene_tax_id_index == -2){
    print "HEADER\n$head\n\n";
    print "Unable to get all the indexes needed\n";
    print "gene_id = $gene_id_index\n";
    print "tax_id = $gene_tax_id_index\n";
    print "symbol = $gene_symbol_index\n";
    print "desc = $gene_desc_index\n";
    print "synonyms = $gene_synonyms_index\n";
    return 0; # this is an error
  }
  my $xref_count = 0;
  my $syn_count  = 0;
  while (<EG>) {
    chomp;
    my (@arr) = split(/\t/,$_);
    if($arr[$gene_tax_id_index] != $species_tax_id){
      next;
    }
    my $acc    = $arr[$gene_id_index];
    my $symbol = $arr[$gene_symbol_index];
    my $desc   = $arr[$gene_desc_index];
    $self->add_xref($acc,"",$symbol,$desc,$source_id,$species_id);
    $xref_count++;

    my (@syn) = split(/\|/ ,$arr[$gene_synonyms_index]);
    foreach my $synonym (@syn){
      $self->add_to_syn($acc, $source_id, $synonym);
      $syn_count++;
    }
  }
  print $xref_count." EntrezGene Xrefs added with $syn_count synonyms\n";
  return 0; #successful
}



sub new {

  my $self = {};
  bless $self, "XrefParser::EntrezGeneParser";
  return $self;

}
 
1;
