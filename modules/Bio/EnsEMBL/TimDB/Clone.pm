#
# BioPerl module for Bio::EnsEMBL::TimDB::Clone
#
# Cared for by Ewan Birney <birney@sanger.ac.uk>
#
# Copyright Ewan Birney
#
# You may distribute this module under the same terms as perl itself

# POD documentation - main docs before the code

=head1 NAME

Bio::EnsEMBL::TimDB::Clone - Perl wrapper over Tim's directories for Clones

=head1 SYNOPSIS

    $clone = Bio::EnsEMBL::TimDB::Clone->new();
 
    $clone->add_Contig($contig);
    

=head1 DESCRIPTION

Describe the object here

=head1 CONTACT

Describe contact details here

=head1 APPENDIX

The rest of the documentation details each of the object
methods. Internal methods are usually preceded with a _

=cut

# Let's begin the code:

package Bio::EnsEMBL::TimDB::Clone;
use vars qw($AUTOLOAD @ISA);
use strict;
use Bio::EnsEMBL::DB::CloneI;
use Bio::EnsEMBL::TimDB::Contig;
use Bio::SeqIO;

use NDBM_File;
use Fcntl qw( O_RDONLY );

# Object preamble - inheriets from Bio::Root::Object
use Bio::Root::Object;

@ISA = qw(Bio::Root::Object Bio::EnsEMBL::DB::CloneI);
# new() is inherited from Bio::Root::Object

# _initialize is where the heavy stuff will happen when new is called
sub _initialize {
  my($self,@args) = @_;
  my $make = $self->SUPER::_initialize(@args);

  # set stuff in self from @args
  my ($dbobj,$id,$cgp,$disk_id,$sv,$emblid,$htgsp,$byacc)=
      $self->_rearrange([qw(DBOBJ
			    ID
			    CGP
			    DISK_ID
			    SV
			    EMBLID
			    HTGSP
			    BYACC
			    )],@args);
  $id || $self->throw("Cannot make contig db object without id");
  $disk_id || $self->throw("Cannot make contig db object without disk_id");
  $dbobj || $self->throw("Cannot make contig db object without db object");
  $dbobj->isa('Bio::EnsEMBL::TimDB::Obj') || 
      $self->throw("Cannot make contig db object with a $dbobj object");
  $cgp || $self->throw("Cannot make a contig db object without location data");

  # id of clone
  $self->id($id);
  
  $self->disk_id($disk_id);
  $self->embl_version($sv);
  $self->embl_id($emblid);
  $self->htg_phase($htgsp);
  $self->byacc($byacc);
  # db object
  $self->_dbobj($dbobj);

  # construct and test the directory of the clone
  my $clone_dir=$dbobj->{'_unfinished_root'}."/$cgp/data/$disk_id";
  my $contig_dbm_file=$dbobj->{'_unfinished_root'}."/$cgp/unfinished_ana.dbm";
  unless(-d $clone_dir){
      $self->throw("Cannot find directory for $disk_id");
  }
  $self->{'_clone_dir'}=$clone_dir;

  # check for sequence file
  if(!-e "$clone_dir/$disk_id.seq"){
      $self->throw("Error: no sequence file for entry $id ($disk_id)");
  }

  # build list of contigs for clone
  # (methods get_all_Contigs and get_Contig look at this list of objects, 
  # rather than build it)
  # FIXME
  # THERE IS CURRENTLY NO QUICK WAY TO LOOK THIS UP!!!
  # getting a list of contigs is currently horrible.  There is a list in the
  # relevant dbm file, however this has to be stepped though.  There
  # is a list in the relevant clone.seq file (headers) except when this file is 
  # absent.  There should be a .gs file for each contig.

  # open dbm for this clone (to check contigs are listed there)
  # NOTE: data stored here, is by disk_id
  my %unfin_contig;
  unless(tie(%unfin_contig,'NDBM_File',$contig_dbm_file,O_RDONLY,0644)){
  #unless(dbmopen(%unfin_contig,$contig_dbm_file,0666)){
      $self->throw("Error opening contig dbm file");
  }
  my($key,$val);
  my %contig_len;
  my %id2disk;
  while(($key,$val)=each %unfin_contig){
      if($key=~/^$disk_id/){
	  my($len,$checksum)=split(/,/,$val);
	  my $disk_key=$key;
	  $key=~s/^$disk_id/$id/;
	  # save by id rather than disk_id, but keep mapping
	  $contig_len{$key}=$len;
	  $self->{'_contig_dna_checksum'}->{$key}=$checksum;
	  $id2disk{$key}=$disk_key;
	  # check for gs file
	  if(!-e "$clone_dir/$disk_key.gs"){
	      $self->throw("Error: no gs file for contig $key");
	  }
      }
  }

  # now build order/orientation information and create @contig_id
  # ordered correctly for next step
  # NOTE: data stored in '_contig_order_hash' has already been converted to id
  my @contig_id;
  my $clone_order=$dbobj->{'_contig_order_hash'}->{$id};
  print STDERR "Order string for $id is: $clone_order\n";
  my $spacing=$Bio::EnsEMBL::DB::CloneI::CONTIG_SPACING;
  my %order;
  my %offset;
  my %orientation;
  my $offset=1;
  if($clone_order){
      # have order information, so use thi
      # (checking that all contigs exist and are used)
      my $ncontig=scalar(keys %contig_len);
      my $ncontig2;
      foreach my $ocontig (split(/[:;]/,$clone_order)){
	  $ncontig2++;
	  my($contig,$fr)=($ocontig=~/(.*)\.([FR])$/);
	  $order{$contig}=$ncontig2;
	  $offset{$contig}=$offset;
	  # forward or reverse
	  if($fr eq 'F'){
	      $orientation{$contig}=1;
	  }else{
	      $orientation{$contig}=-1;
	  }
	  # offset is length + separation
	  if($contig_len{$contig}){
	      $offset+=$contig_len{$contig}+$spacing;
	  }else{
	      $self->throw("Contig in contigorder \'$contig\' not in DBM file [\'$id\',\'$ocontig\']");
	  }
	  push(@contig_id,$contig);
      }
      if($ncontig!=$ncontig2){
	  $self->throw("More contigs in DBM file ($ncontig) than in contigorder file ($ncontig2)");
      }
  }else{
      # no order information, order contigs by length
      # FIXME?
      # (perhaps should keep EMBL order in such cases, but don't have that data
      #  unless order by contig number (ok for non sanger clones))
      my $ncontig2;
      foreach my $contig (sort {$contig_len{$a}<=>$contig_len{$b}} keys %contig_len){
	  $ncontig2++;
	  $order{$contig}=$ncontig2;
	  $offset{$contig}=$offset;
	  # always forward
	  $orientation{$contig}=1;
	  # offset is length + separation
	  $offset+=$contig_len{$contig}+$spacing;
	  push(@contig_id,$contig);
      }
  }

  my @res;
  foreach my $contig_id (@contig_id){
      my $disk_contig_id=$id2disk{$contig_id};
      print STDERR "Attempting to retrieve contig with $disk_contig_id [$contig_id]\n";
      my $contig = new Bio::EnsEMBL::TimDB::Contig ( -dbobj => $self->_dbobj,
						     -id => $contig_id,
						     -disk_id => $disk_contig_id,
						     -clone_dir => $self->{'_clone_dir'},
						     -order => $order{$contig_id},
						     -offset => $offset{$contig_id},
						     -orientation => $orientation{$contig_id},
						     '-length' => $contig_len{$contig_id},
						     );
      push(@res,$contig);
  }
  $self->{'_contig_array'}=\@res;

  # DEBUG
  print STDERR scalar(@{$self->{'_contig_array'}})." contigs found in clone\n";

  return $make; # success - we hope!
}


=head2 get_all_Contigs

 Title   : get_all_Contigs
 Usage   :
 Function:
 Example :
 Returns : 
 Args    :

=cut

sub get_all_Contigs{
   my ($self) = @_;
   return @{$self->{'_contig_array'}};
}


=head2 get_Contig

 Title   : get_Contig
 Usage   :
 Function:
 Example :
 Returns : contig object
 Args    : contig_id

=cut

sub get_Contig {
    my ($self,$contigid) = @_;
    my $c;
    foreach my $contig (@{$self->{'_contig_array'}}){
	if( $contigid eq $contig->id()){
	    $c=$contig;
	    last;
	}
    }
    unless($c){
	$self->throw("contigid $contigid not found in this clone");
    }
    return $c;
}


=head2 add_Contig

 Title   : add_Contig
 Usage   :
 Function:
 Example :
 Returns : 
 Args    :

=cut

sub add_Contig{
   my ($self,$contig) = @_;
   $self->throw("Cannot add items to TimDB");
}


=head2 get_all_Genes

 Title   : get_all_Genes
 Usage   :
 Function:
 Example :
 Returns : 
 Args    :

=cut

sub get_all_Genes{
    my ($self,$evidence) = @_;
    my %h;
    
    # map if not already mapped
    $self->_dbobj->map_etg unless $self->_dbobj->{'_mapped'};

    my @features;

    foreach my $contig ($self->get_all_Contigs) {

	if ($evidence eq 'evidence') {
	    push(@features,$contig->get_all_SimilarityFeatures);
	}

	foreach my $gene ($contig->get_all_Genes){
	    # read into a hash to make unique
	    $h{$gene->id()} = $gene;
	}
    }

    # Now attach the evidence if necessary
    if ($evidence eq 'evidence') {
	foreach my $gene (values %h) {
	    foreach my $exon ($gene->each_unique_Exon) {
		$exon ->find_supporting_evidence (\@features);
	    }
	}
    }
    # DEBUG
    print STDERR "Clone contains ".scalar(keys %h)." genes\n";
    return values %h;
}

#
# Seq method from the cloneI object now
#


=head2 id

 Title   : id
 Usage   : $obj->id($newval)
 Function: 
 Example : 
 Returns : value of id
 Args    : newvalue (optional)

=cut

sub id {
    my ($obj,$value) = @_;
    if( defined $value) {
	$obj->{'_clone_id'} = $value;
    }
    return $obj->{'_clone_id'};
}


sub disk_id {
    my ($obj,$value) = @_;
    if( defined $value) {
	$obj->{'_clone_disk_id'} = $value;
    }
    return $obj->{'_clone_disk_id'};
}


=head2 _dbobj

 Title   : _dbobj
 Usage   : $obj->_dbobj($newval)
 Function: 
 Example : 
 Returns : value of _dbobj
 Args    : newvalue (optional)

=cut

sub _dbobj {
    my ($obj,$value) = @_;
    if( defined $value) {
	$obj->{'_dbobj'} = $value;
    }
    return $obj->{'_dbobj'};
}

=head2 embl_id

 Title   : embl_id
 Usage   : this is the embl_id for this clone, to generate nice looking files
 Function:
 Example :
 Returns : 
 Args    :


=cut

sub embl_id {
    my ($obj,$value) = @_;
    if( defined $value) {

	# FIXME
	# may be '' - what to do in this case?

	$obj->{'_clone_embl_id'} = $value;
    }
    return $obj->{'_clone_embl_id'};
}


=head2 sv

 Title   : sv
 Function: returns the version number (not the acc.version, just verision).
 Example :
 Returns : 
 Args    :


=cut

sub sv {
    my($self)=@_;
    $self->warn("DEPRECATING METHOD replace \$self->sv with \$self->embl_version");
    return $self->embl_version;
}


=head2 htg_phase

 Title   : htg_phase
 Usage   : this is the phase being 0,1,2,3,4 (4 being finished).
 Function:
 Example :
 Returns : 
 Args    :


=cut

sub htg_phase {
    my ($obj,$value) = @_;
    if( defined $value) {
	if($value=~/^[01234]$/){
	    $obj->{'_clone_htgsp'} = $value;
	}else{
	#    $obj->throw("Invalid value for htg_phase $value");
	     $obj->warn("Invalid value for htg_phase $value. Storing undef for the moment");
	}
    }
    return $obj->{'_clone_htgsp'};
}


=head2 byacc

 Title   : byacc
 Usage   : $obj->byacc($newval)
 Function: 
 Returns : value of byacc
 Args    : newvalue (optional)


=cut

sub byacc{
   my $obj = shift;
   if( @_ ) {
      my $value = shift;
      $obj->{'byacc'} = $value;
    }
    return $obj->{'byacc'};

}


=head2 compare_dna

 Title   : compare_dna
 Usage   : $obj->compare_dna($file)
 Function: 
 Returns : 1 if dna in $file is different (checksum comparision) to dna in clone object
 Args    : newvalue (optional)


=cut

sub compare_dna{
    my $self = shift;
    my $file = shift;
    print "Comparing with $file\n";
    my $seqio=Bio::SeqIO->new( '-format' => 'Fasta', -file => $file);
    my $fseq;
    my %contigs;
    my $checksum2;
    my $eflag=0;
    my $id=$self->id;
    my $disk_id=$self->disk_id;
    while($fseq=$seqio->next_seq()){
	my $seqid=$fseq->id;
	$seqid=~s/^$disk_id/$id/;
	my $seqlen=$fseq->seq_len;
	my $seq=$fseq->seq;
	my $checksum=unpack("%32C*",$seq) % 32767;
	if($checksum2=$self->{'_contig_dna_checksum'}->{$seqid}){
	    $contigs{$seqid}=1;
	    if($checksum==$checksum2){
		print STDERR "Contig $seqid same in Ensembl: $checksum $checksum2\n";
	    }else{
		print STDERR "ERROR: Contig $seqid different in Ensembl: $checksum $checksum2\n";
		$eflag=1;
	    }
	}else{
	    print STDERR "ERROR: Contig $seqid not in Ensembl\n";
	    $eflag=1;
	}
    }
    foreach my $contig (keys %{$self->{'_contig_dna_checksum'}}){
	if(!$contigs{$contig}){
	    print STDERR "ERROR: Contig $contig only in Ensembl\n";
	}
    }
    return $eflag;
}


=head2 embl_version

 Title   : embl_version
 Usage   : $clone->embl_version()
 Function: Gives the value of the EMBL version, i.e. the sequence data version [SV]
 Example : $clone->embl_version()
 Returns : version number
 Args    : none


=cut

sub embl_version {
    my ($obj,$value) = @_;
    if (defined $value) {
        $value ||= -1;
	if ($value =~ /^-?\d+$/) {
	    $obj->{'_clone_sv'} = $value;
	} else {
	    $obj->throw("Invalid value for embl_version [SV] '$value'");
	}
    }
    return $obj->{'_clone_sv'};
}

=head2 seq_date

 Title   : seq_date
 Usage   : $clone->seq_date()
 Function: In TimDB there is one DNA file per clone, so just checks this date
 Example : $clone->seq_date()
 Returns : unix time
 Args    : none


=cut

sub seq_date {
    my ($self) = @_;
    my $dnafile=$self->{'_clone_dir'}."/".$self->disk_id.".seq";
    my $dnafiledate=(stat($dnafile))[9];
    return $dnafiledate;
}


=head2 version

 Title   : version
 Function: Schema translation
 Example :
 Returns : 
 Args    :


=cut

sub version {
    my ($self,@args) = @_;
    # this value is incremented each time a clone is unlocked after processing in TimDB
    return $self->_clone_status(6);
}


=head2 created

 Title   : created
 Usage   : $clone->created()
 Function: Gives the unix time value of the created datetime field, which indicates
           the first time this clone was put in ensembl
 Example : $clone->created()
 Returns : unix time
 Args    : none


=cut

sub created {
    my ($self) = @_;
    # this value is the time set when a clone is unlocked after being first created in TimDB
    return $self->_clone_status(5);
}


=head2 modified

 Title   : modified
 Usage   : $clone->modified()
 Function: Gives the unix time value of the modified datetime field, which indicates
           the last time this clone was modified in ensembl
 Example : $clone->modified()
 Returns : unix time
 Args    : none


=cut

sub modified{
    my ($self) = @_;
    # this value is the time set when a clone is unlocked in TimDB
    return $self->_clone_status(0);
}

sub _clone_status{
    my($self,$field)=@_;
    my $disk_id=$self->disk_id;
    my $val=$self->_dbobj->{'_clone_update_dbm'}->{$disk_id};
    if(!$val){
	my $id=$self->id;
	$self->throw("No Status entry for $disk_id [$id]");
    }
    my @fields=split(',',$val);
    return $fields[$field];
}

1;
