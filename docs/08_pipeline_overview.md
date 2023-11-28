This workflow is designed to perform variant calling of small variants, structural
variants and modified bases aggregation from paired tumor/normal BAM files
for a single sample.

Per-sample files will be prefixed with respective aliases and represented
below as {{ alias }}. Outputs per tumor or normal are represented
below as {{ type }}. Outputs for different changes (e.g. 5mC or 5hmC)
are represented below as {{ change }}. {{ format }} may refer to either BAM
or CRAM, and {{ format_index }} may refer to either BAI or CRAI.

### 1. Input and data preparation.

The workflow relies on three primary input files:
1. A reference genome in [fasta format](https://www.ncbi.nlm.nih.gov/genbank/fastaformat/)
2. A [BAM file](https://samtools.github.io/hts-specs/SAMv1.pdf) for the tumor sample (either aligned or unaligned)
3. A [BAM file](https://samtools.github.io/hts-specs/SAMv1.pdf) for the normal sample (either aligned or unaligned)

The BAM files can be generated from:
1. [POD5](https://github.com/nanoporetech/pod5-file-format)/[FAST5](https://github.com/nanoporetech/ont_fast5_api) files using the [wf-basecalling](https://github.com/epi2me-labs/wf-basecalling) workflow, or
2. [fastq](https://www.ncbi.nlm.nih.gov/sra/docs/submitformats/#fastq) files using [wf-alignment](https://github.com/epi2me-labs/wf-alignment).
Both workflows will generate aligned BAM files that are ready to be used with `wf-somatic-variation`.

### 2. Data QC and pre-processing.
The workflow starts by performing multiple checks of the input BAM files, as well as computing:
1. The depth of sequencing of each BAM file with [mosdepth](https://github.com/brentp/mosdepth).
2. The read alignment statistics for each BAM file with [fastcat](https://github.com/epi2me-labs/fastcat).

After computing the coverage, the workflow will check that the input BAM files have a depth greater than
`--tumor_min_coverage` and `--normal_min_coverage` for the tumor and normal BAM files, respectively.
It is necessary that **both** BAM files have passed the respective thresholds. In cases where the user
sets the minimum coverage to `0`, the check will be skipped and the workflow will proceed directly to the
downstream analyses.

### 3. Somatic short variants calling with ClairS.

The workflow currently implements a deconstructed version of [ClairS](https://github.com/HKU-BAL/ClairS)
(v0.1.6) to identify somatic variants in a paired tumor/normal sample. 
This workflow takes advantage of the parallel nature of Nextflow, providing optimal efficiency in
high-performance, distributed systems.

Currently, ClairS supports the following basecalling models:

| Workflow basecalling model | ClairS model |
|----------------------------|--------------|
| dna_r10.4.1_e8.2_400bps_sup@v4.2.0 | ont_r10_dorado_5khz |
| dna_r10.4.1_e8.2_400bps_sup@v4.1.0 | ont_r10_dorado_4khz |
| dna_r10.4.1_e8.2_400bps_sup@v3.5.2 | ont_r10_guppy |
| dna_r9.4.1_e8_hac@v3.3 | ont_r9_guppy |
| dna_r9.4.1_e8_sup@v3.3 | ont_r9_guppy |
| dna_r9.4.1_450bps_hac_prom | ont_r9_guppy |
| dna_r9.4.1_450bps_hac | ont_r9_guppy |

Any other model provided will prevent the workflow to start. 

Currently, indel calling is supported only for `dna_r10` basecalling models.
When the user specifies an r9 model the workflow will automatically skip
the indel processes and perform only the SNV calling. 

The workflow uses `Clair3` to call germline sites on both the normal and tumor
sample, which are then used internally to refine the somatic variant calling.
This mode is computationally demanding, and it's behaviour can be changed with
a few options:
* Reduce the accuracy of the variant calling with `--fast_mode`.
* Provide a pre-computed VCF file reporting the germline calls for the normal sample with `--normal_vcf`.
* Disable the germline calling altogether with `--germline false`.

SNVs can be annotated using [SnpEff](https://pcingola.github.io/SnpEff/) by
setting `--annotation true`. Furthermore, the workflow will add annotations from
the [ClinVar](https://www.ncbi.nlm.nih.gov/clinvar/) database.


### 4. Somatic structural variant (SV) calling with Nanomonsv.

The workflow allows for the calling of somatic SVs using long-read sequencing data.
Starting from the paired cancer/control samples, the workflow will:
1. Parse the SV signatures in the reads using `nanomonsv parse`
2. Call the somatic SVs using `nanomonsv get`
3. Filter out the SVs in simple repeats using `add_simple_repeat.py` (*optional*)
4. Annotate transposable and repetitive elements using `nanomonsv insert_classify` (*optional*)

As of `nanomonsv` v0.7.1 (and v0.4.0 of this workflow), users can provide
the approximate single base quality value (QV) for their dataset.
To decide which is the most appropriate value for your dataset, visit the
`get` section of the `nanomonsv` [web page](https://github.com/friend1ws/nanomonsv#get),
but it can be summarized as follow:

|     Basecaller     |  Quality value  |
|--------------------|-----------------|
|     guppy (v5)     |       10        |
|  guppy (v5 or v6)  |       15        |
|       dorado       |       20        |

To provide the correct qv value, simply use `--qv 20`.

The VCF produced by nanomonsv is now processed to have one sample with the
name specified with `--sample_name` (rather than the two-sample
`TUMOR`/`CONTROL`). The original VCFs generated by nanomonsv are now
saved as `{{ alias }}/sv/vcf/{{ alias }}.results.nanomonsv.vcf`.

SVs can be annotated using [SnpEff](https://pcingola.github.io/SnpEff/) by
setting `--annotation true`.

### 5. Modified base calling with modkit

Modified base calling can be performed by specifying `--mod`. The workflow
will aggregate the modified bases using [modkit](https://github.com/nanoporetech/modkit) and
perform differential modification analyses using [DSS](https://bioconductor.org/packages/DSS/). 
The default behaviour of the workflow is to run modkit with the 
`--cpg --combine-strands` options set.
It is possible to report strand-aware modifications by providing `--force_strand`.
Users can further change the behaviour of `modkit` by passing options directly
to modkit via the `--modkit_args` option. This will override any preset,
and allow full control over the run of modkit. For more details on the usage
of `modkit pileup`, checkout the software [documentation](https://nanoporetech.github.io/modkit/).