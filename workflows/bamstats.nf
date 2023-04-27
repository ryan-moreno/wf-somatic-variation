process bamstats {
    cpus 4
    input:
        tuple path(xam), path(xam_idx), val(xam_meta)
        path target_bed
        tuple path(ref), path(ref_idx), path(ref_cache)

    output:
        tuple val(xam_meta), path("*.readstats.tsv.gz"), emit: read_stats
        tuple val(xam_meta), path("*.flagstat.tsv"), emit: flagstat
    script:
    def ref_path = "${ref_cache}/%2s/%2s/%s:" + System.getenv("REF_PATH")
    def cores = task.cpus > 1 ? task.cpus - 1 : 1
    """
    export REF_PATH="${ref_path}"
    bamstats ${xam} -s ${xam_meta.sample} --threads ${cores} -u -f ${xam_meta.sample}_${xam_meta.type}.flagstat.tsv | gzip > ${xam_meta.sample}_${xam_meta.type}.readstats.tsv.gz
    """
}

process mosdepth {
    cpus 2
    input:
        tuple path(xam), path(xam_idx), val(xam_meta)
        file target_bed
        tuple path(ref), path(ref_idx), path(ref_cache)
    output:
        tuple val(xam_meta), \
            path("${xam_meta.sample}_${xam_meta.type}.regions.bed.gz"),
            path("${xam_meta.sample}_${xam_meta.type}.mosdepth.global.dist.txt"),
            path("${xam_meta.sample}_${xam_meta.type}.thresholds.bed.gz"), emit: mosdepth_tuple
        tuple val(xam_meta), path("${xam_meta.sample}_${xam_meta.type}.mosdepth.summary.txt"), emit: summary
        tuple val(xam_meta), path("${xam_meta.sample}_${xam_meta.type}.per-base.bed.gz"), emit: perbase, optional: true
    script:
        """
        export REF_PATH=${ref}
        export MOSDEPTH_PRECISION=3
        mosdepth \
        -x \
        -t $task.cpus \
        -b ${target_bed} \
        --thresholds 1,10,20,30 \
        ${xam_meta.sample}_${xam_meta.type} \
        $xam

        """
}

// Get coverage to a channel
process get_coverage {
    cpus 1
    input:
        tuple val(meta), path(mosdepth_summary)

    output:
        tuple val(meta.sample), val(meta), env(passes), env(value), emit: pass

    shell:
        '''
        passes=$( awk 'BEGIN{v="false"}; NR>1 && $1~"total" && $4>=!{meta.type == "tumor" ? params.tumor_min_coverage : params.normal_min_coverage} && v=="false" {v="true"}; END {print v}' !{mosdepth_summary} )
        value=$( awk 'BEGIN{v=0}; NR>1 && $1~"total" && $4>v {v=$4}; END {print v}' !{mosdepth_summary} )
        '''
}

// Get coverage to a channel
process discarded_sample {
    cpus 1
    input:
        tuple val(sample), val(meta), val(passing), val(coverage)

    output:
        tuple val(sample), val(meta), val(coverage), env(threshold), emit: failed

    shell:
        '''
        threshold=!{meta.type =='tumor' ? params.tumor_min_coverage : params.normal_min_coverage}
        '''
}

// Make report
process makeQCreport {
    input: 
        tuple val(meta), 
            path("readstats_normal.tsv.gz"),
            path("flagstat_normal.tsv"),
            path("depths_normal.bed.gz"),
            path("summary_depth_normal.tsv"),
            path("readstats_tumor.tsv.gz"),
            path("flagstat_tumor.tsv"),
            path("depths_tumor.bed.gz"),
            path("summary_depth_tumor.tsv")
        path versions
        path params
        val tumor_min_coverage
        val normal_min_coverage

    output:
        tuple val(meta), path("${meta.sample}.wf-somatic-variation-readQC*.html")

    script:
        """
        workflow-glue report_qc \\
            --tumor_cov_threshold ${tumor_min_coverage} \\
            --normal_cov_threshold ${normal_min_coverage} \\
            --sample_id ${meta.sample} \\
            --name ${meta.sample}.wf-somatic-variation-readQC \\
            --read_stats_normal readstats_normal.tsv.gz \\
            --read_stats_tumor readstats_tumor.tsv.gz \\
            --depth_tumor depths_tumor.bed.gz \\
            --depth_normal depths_normal.bed.gz \\
            --flagstat_tumor flagstat_tumor.tsv \\
            --flagstat_normal flagstat_normal.tsv \\
            --mosdepth_summary_tumor summary_depth_tumor.tsv \\
            --mosdepth_summary_normal summary_depth_normal.tsv \\
            --versions versions.txt \\
            --params params.json 
        """
}


process output_qc {
    // publish inputs to output directory
    publishDir (
        params.out_dir,
        mode: "copy",
        saveAs: { dirname ? "$dirname/$fname" : fname }
    )
    input:
        tuple path(fname), val(dirname)
    output:
        path fname
    """
    """
}


workflow alignment_stats {
    take:
        bamfiles
        ref
        bed
        versions
        parameters
    
    main:
        // Compute bam statistics and depth
        stats = bamstats(bamfiles, bed, ref.collect())
        depths = mosdepth(bamfiles, bed, ref.collect())

        // Combine the outputs for the different statistics.
        // Fo the reporting we will need:
        // 1. Read stats
        // 2. flagstats
        // 3. Per-base depth
        // 4. Depth summary
        stats.read_stats.map{it->[it[0], it[1]]}
            .combine(stats.flagstat.map{it->[it[0], it[1]]}, by:0)
            .combine(depths.perbase.map{it->[it[0], it[1]]}, by:0)
            .combine(depths.summary.map{it->[it[0], it[1]]}, by:0)
            .set{ for_report }

        // Cross the results for T/N pairs
        for_report
            .branch{
                tumor: it[0].type == 'tumor'
                normal: it[0].type == 'normal'
            }
            .set{forked_channel}
        forked_channel.normal
            .map{ it -> [ it[0].sample ] + it } 
            .cross(
                forked_channel.tumor.map{ it -> [ it[0].sample ] + it } 
            )
            .map { normal, tumor ->
                    [tumor[1]] + normal[2..-1] + tumor[2..-1]
                } 
            .set{paired_samples}

        makeQCreport(paired_samples, versions, parameters, params.tumor_min_coverage, params.normal_min_coverage)

        // Prepare output channel
        // Send the output to the specified sub-directory of params.out_dir.
        // If null is passed, send it to out_dir/ directly.
        makeQCreport.out.map{it -> [it[1], null]}
            .concat(stats.flagstat.map{it->[it[1], "qc/${it[0].sample}/readstats"]})
            .concat(stats.read_stats.map{it->[it[1], "qc/${it[0].sample}/readstats"]})
            .concat(depths.summary.map{it->[it[1], "qc/${it[0].sample}/coverage"]})
            .concat(depths.mosdepth_tuple
                        .map {it -> [it[0], it[1..-1]] }
                        .transpose()
                        .map{it -> [it[1], "qc/${it[0].sample}/coverage"]})
            .concat(depths.perbase.map{it->[it[1], "qc/${it[0].sample}/coverage"]})
            .set{outputs}

        emit:
            outputs = outputs
            coverages = depths.summary
            paired_qc = paired_samples
}