USE [MYDB]
GO

/****** Object:  View [dbo].[v_INDUS_ESG_ECR_FIN]    Script Date: 2026/9/11 下午 05:46:16 ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO





/*
==================================================
20240911  IT20202408051049 碳排盤查所需

*/

ALTER VIEW [dbo].[v_INDUS_ESG_ECR_FIN] AS

-- ifrs / fiifrs
SELECT
	A.CF_CASENO, A.CF_COMID, A.CF_MMYYYY, A.CF_RFNBR, A.CF_CUSTTYPE, A.CF_CRCTYPE, A.CF_FSRFNBR, c.CE_BANBR, 
	c.CE_AMOUNT, convert(varchar(100),'') as FA_CNAME, CASE WHEN A.CF_BSTYPE IS NOT NULL THEN 'FIIFRS' ELSE 'IFRS' END AS BS_TYP, 
	convert(varchar(8),getdate(),112) as IMP_DATE, '925' as GLOBAL_BRANCH
FROM ECR_IFRS_CASE_FINSTATE A with(nolock)
JOIN 
(
	-- 若同時有單一、合併財報，以合併財報為主
	SELECT CF_COMID, CF_CUSTTYPE, MAX(CF_FSRFNBR) CF_FSRFNBR, 
		ROW_NUMBER() OVER (PARTITION BY CF_COMID ORDER BY CF_CUSTTYPE DESC) AS SEQ
	FROM ECR_IFRS_CASE_FINSTATE with(nolock)
	WHERE CF_MMPERD = '12'	
	GROUP BY CF_COMID, CF_CUSTTYPE
) B ON A.CF_COMID = B.CF_COMID AND A.CF_FSRFNBR = B.CF_FSRFNBR AND B.SEQ=1
join ECR_ifrs_case_fsvalue c with(nolock) on a.cf_comid=c.ce_comid and a.cf_rfnbr=c.cf_rfnbr
--join dbo.ifrs_fs_actlst d on c.ce_banbr=d.fa_rfnbr
WHERE a.CF_MMPERD = '12'

union all

/* 取得GAAP 各ID最新完整年度財報，排除已有IFRS / FIIFRS財報者  */
SELECT A.CF_CASENO, A.CF_COMID, A.CF_MMYYYY, A.CF_RFNBR, A.CF_CUSTTYPE, A.CF_CRCTYPE, A.CF_FSRFNBR, 
	convert(varchar(7),c.CE_BANBR) as CE_BANBR, c.CE_AMOUNT, d.CT_CNAME, 'GAAP' BS_TYP, 
	convert(varchar(8),getdate(),112) as IMP_DATE, '925' as  GLOBAL_BRANCH
FROM ECR_CASE_FINSTATE A with(nolock)
INNER JOIN 
(
	SELECT CF_COMID, CF_CUSTTYPE, MAX(CF_FSRFNBR) CF_FSRFNBR,
		ROW_NUMBER() OVER (PARTITION BY CF_COMID ORDER BY CF_CUSTTYPE DESC) AS SEQ
	FROM ECR_CASE_FINSTATE with(nolock)
	WHERE CF_MMPERD = '12'	
	GROUP BY CF_COMID, CF_CUSTTYPE
) B ON A.CF_COMID = B.CF_COMID AND A.CF_FSRFNBR = B.CF_FSRFNBR AND B.SEQ=1
join ECR_case_fsvalue c with(nolock) on a.cf_comid=c.ce_comid and a.CF_FSRFNBR=c.ce_fsbr
join ECR_case_fsactlst d with(nolock) on c.ce_banbr=d.ct_rfnbr
WHERE CF_MMPERD = '12'
-- 排除此ID已有ifrs / fiifrs
AND NOT EXISTS 
(
	select 1
	FROM ECR_IFRS_CASE_FINSTATE A1 with(nolock)
	JOIN 
	(
		-- 若同時有單一、合併財報，以合併財報為主
		SELECT CF_COMID, CF_CUSTTYPE, MAX(CF_FSRFNBR) CF_FSRFNBR, 
			ROW_NUMBER() OVER (PARTITION BY CF_COMID ORDER BY CF_CUSTTYPE DESC) AS SEQ
		FROM ECR_IFRS_CASE_FINSTATE with(nolock)
		WHERE CF_MMPERD = '12'	
		GROUP BY CF_COMID, CF_CUSTTYPE
	) B1 ON A1.CF_COMID = B1.CF_COMID AND A1.CF_FSRFNBR = B1.CF_FSRFNBR AND B1.SEQ=1	
	join ECR_ifrs_case_fsvalue c1 with(nolock) on a1.cf_comid=c1.ce_comid and a1.cf_rfnbr=c1.cf_rfnbr
	WHERE a1.CF_MMPERD = '12'
	and a.cf_comid=a1.cf_comid
)


GO

