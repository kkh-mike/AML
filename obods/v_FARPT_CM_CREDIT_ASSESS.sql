USE [MYDB]
GO

/****** Object:  View [dbo].[v_FARPT_CM_CREDIT_ASSESS]    Script Date: 2026/9/11 下午 05:45:56 ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO






/*
 * 用途：整合新舊評定表單
 * 修改歷程
 * -----------------------------------
 * 20241017	1020693	初版 (僅供FARPT系統使用)
 */ 

ALTER view [dbo].[v_FARPT_CM_CREDIT_ASSESS] as 
	
	select 
		'納閔' as BRANCH_NM, ca.CASEFORMLIST_SN, ca.CR_CO_ID, ca.CR_CO_NAME, ca.CR_APP_DEPNAME, ca.CR_RMNAME,
		ca.CR_APP_DATE, ca.CR_FIN_DATE, cast(ca.CR_BREAK_PERCENT as varchar(20)) as CR_BREAK_PERCENT,
		cast(ca.CR_DF_BP as varchar(20)) as CR_DF_BP, ca.CR_CGRADE, cast(ca.CR_SCORING as varchar(20)) as CR_SCORING,
		ca.CR_NET_VALUE, cat.cat_type AS CR_ASSESS_TOOL, ca.CR_DRAW_CGRADE, ca.CR_ADVISE_CGRADE, ca.CR_CREDIT_CGRADE, 
		CONVERT(DATETIME,ca.CR_CREDIT_DATE,111) as CR_CREDIT_DATE, ca.CR_MODIFY_BR_USERID,
		ca.CR_MODIFY_BR_TIME, dbo.FUN_CML_CREDIT_REASON(ca.CASEFORMLIST_SN) AS CML_CREDIT_REASON, ca.CR_ROLE60_ADVISE_CGRADE,
		ca.CR_ROLE60_REASON, ca.CR_ASSESS_CGRADE, ca.CR_IS_MODIFY, ca.CR_ASSESS_DATE,
		-- 20240604 新增欄位
		'' as quantity, '' as rm_quality, '' as rm_cr_scoring, '' as rm_cr_score_cgrade, '' as rm_cr_advise_cgrade,
		'' as censor_quality, '' as censor_cr_scoring, '' as censor_cr_score_cgrade, '' as censor_advise_cgrade,
		'' as quality, '' as cr_scoring_new, '' as cr_score_cgrade, ca.cr_assess_level, 'CM011' as RPT_SRC
	from dbo.ECR_CM_CREDIT_ASSESS ca
	left join dbo.ECR_cml_assess_tool cat on cat.cat_rfnbr=ca.CR_ASSESS_TOOL
	union all
	select 
		'納閔' as BRANCH_N, ca.CASEFORMLIST_SN, ca.CR_CO_ID, ca.CR_CO_NAME, ca.CR_APP_DEPNAME, ca.CR_RMNAME,
		ca.CR_APP_DATE, ca.CR_FIN_DATE, '' as CR_BREAK_PERCENT,
		-- 新版違約機率對照
		case when ca.cr_assess_cgrade='1' then  '0.0500'
			 when ca.cr_assess_cgrade='2+' then '0.0850'
			 when ca.cr_assess_cgrade='2-' then '0.0914'
			 when ca.cr_assess_cgrade='3+' then '0.0978'
			 when ca.cr_assess_cgrade='3-' then '0.1042'
			 when ca.cr_assess_cgrade='4+' then '0.1781'
			 when ca.cr_assess_cgrade='4-' then '0.2857'
			 when ca.cr_assess_cgrade='5+' then '0.4231'
			 when ca.cr_assess_cgrade='5-' then '0.7344'			 
			 when ca.cr_assess_cgrade='6+' then '0.9265'
			 when ca.cr_assess_cgrade='6-' then '1.2224'
			 when ca.cr_assess_cgrade='7+' then '2.7251'
			 when ca.cr_assess_cgrade='7-' then '3.5260'
			 when ca.cr_assess_cgrade='8+' then '4.1566'
			 when ca.cr_assess_cgrade='8-' then '6.6549'
			 when ca.cr_assess_cgrade='9' then '17.4410'
			 when ca.cr_assess_cgrade='10' then '34.4568'
			 when ca.cr_assess_cgrade='D' then '100.0000'
			 when ca.cr_assess_cgrade='P1+' then '0.4231'
			 when ca.cr_assess_cgrade='P1' then '0.7344'
			 when ca.cr_assess_cgrade='P1-' then '0.9265'
		else '' end  as CR_DF_BP,
		'' as CR_CGRADE, cast(ca.CR_SCORING as varchar(20)) as CR_SCORING,
		ca.CR_NET_VALUE, cat.cat_type AS CR_ASSESS_TOOL, '' as CR_DRAW_CGRADE, '' as CR_ADVISE_CGRADE, ca.CR_CREDIT_CGRADE, 
		CONVERT(DATETIME,ca.CR_CREDIT_DATE,111),'' as CR_MODIFY_BR_USERID,
		'' as CR_MODIFY_BR_TIME, dbo.FUN_CML_CREDIT_REASON(ca.CASEFORMLIST_SN) AS CML_CREDIT_REASON, 
		ca.censor_advise_cgrade as CR_ROLE60_ADVISE_CGRADE, ca.censor_opinion as CR_ROLE60_REASON, ca.CR_ASSESS_CGRADE, 
		ca.CR_IS_MODIFY, ca.CR_ASSESS_DATE, 
		-- 20240604 新增欄位
		ca.quantity, ca.rm_quality, convert(varchar(50),ca.rm_cr_scoring) as rm_cr_scoring, ca.rm_cr_score_cgrade, ca.rm_cr_advise_cgrade,
		ca.censor_quality, convert(varchar(50),ca.censor_cr_scoring) as censor_cr_scoring, ca.censor_cr_score_cgrade, ca.censor_advise_cgrade,
		ca.quality, convert(varchar(50),ca.cr_scoring) as rm_cr_scoring_new, ca.cr_score_cgrade, ca.cr_assess_level, 'CM011A' as RPT_SRC
	from dbo.ECR_CM_CREDIT_ASSESS_A ca
	join dbo.ECR_CASE_FORM_LIST cfl on ca.caseformlist_sn=cfl.caseformlist_sn and cfl.caseformlist_form_id='CM011A'
	left join dbo.ECR_cml_assess_tool cat on cat.cat_rfnbr=ca.CR_ASSESS_TOOL
		union all
	select 
		'納閔' as BRANCH_N, ca.CASEFORMLIST_SN, ca.CR_CO_ID, ca.CR_CO_NAME, ca.CR_APP_DEPNAME, ca.CR_RMNAME,
		ca.CR_APP_DATE, ca.CR_FIN_DATE, '' as CR_BREAK_PERCENT,
		-- 新版違約機率對照
		case when ca.cr_assess_cgrade='1' then  '0.0500'
			 when ca.cr_assess_cgrade='2+' then '0.0850'
			 when ca.cr_assess_cgrade='2-' then '0.0914'
			 when ca.cr_assess_cgrade='3+' then '0.0978'
			 when ca.cr_assess_cgrade='3-' then '0.1042'
			 when ca.cr_assess_cgrade='4+' then '0.1781'
			 when ca.cr_assess_cgrade='4-' then '0.2857'
			 when ca.cr_assess_cgrade='5+' then '0.4231'
			 when ca.cr_assess_cgrade='5-' then '0.7344'			 
			 when ca.cr_assess_cgrade='6+' then '0.9265'
			 when ca.cr_assess_cgrade='6-' then '1.2224'
			 when ca.cr_assess_cgrade='7+' then '2.7251'
			 when ca.cr_assess_cgrade='7-' then '3.5260'
			 when ca.cr_assess_cgrade='8+' then '4.1566'
			 when ca.cr_assess_cgrade='8-' then '6.6549'
			 when ca.cr_assess_cgrade='9' then '17.4410'
			 when ca.cr_assess_cgrade='10' then '34.4568'
			 when ca.cr_assess_cgrade='D' then '100.0000'
			 when ca.cr_assess_cgrade='P1+' then '0.4231'
			 when ca.cr_assess_cgrade='P1' then '0.7344'
			 when ca.cr_assess_cgrade='P1-' then '0.9265'
		else '' end  as CR_DF_BP,
		'' as CR_CGRADE, cast(ca.CR_SCORING as varchar(20)) as CR_SCORING,
		ca.CR_NET_VALUE, cat.cat_type AS CR_ASSESS_TOOL, '' as CR_DRAW_CGRADE, '' as CR_ADVISE_CGRADE, ca.CR_CREDIT_CGRADE, 
		CONVERT(DATETIME,ca.CR_CREDIT_DATE,111),'' as CR_MODIFY_BR_USERID,
		'' as CR_MODIFY_BR_TIME, dbo.FUN_CML_CREDIT_REASON(ca.CASEFORMLIST_SN) AS CML_CREDIT_REASON, 
		ca.censor_advise_cgrade as CR_ROLE60_ADVISE_CGRADE, ca.censor_opinion as CR_ROLE60_REASON, ca.CR_ASSESS_CGRADE, 
		ca.CR_IS_MODIFY, ca.CR_ASSESS_DATE, 
		-- 20240604 新增欄位
		ca.quantity, ca.rm_quality, convert(varchar(50),ca.rm_cr_scoring) as rm_cr_scoring, ca.rm_cr_score_cgrade, ca.rm_cr_advise_cgrade,
		ca.censor_quality, convert(varchar(50),ca.censor_cr_scoring) as censor_cr_scoring, ca.censor_cr_score_cgrade, ca.censor_advise_cgrade,
		ca.quality, convert(varchar(50),ca.cr_scoring) as rm_cr_scoring_new, ca.cr_score_cgrade, ca.cr_assess_level, 'CM011B' as RPT_SRC
	from dbo.ECR_CM_CREDIT_ASSESS_A ca
	join dbo.ECR_CASE_FORM_LIST cfl on ca.caseformlist_sn=cfl.caseformlist_sn and cfl.caseformlist_form_id='CM011B'
	left join dbo.ECR_cml_assess_tool cat on cat.cat_rfnbr=ca.CR_ASSESS_TOOL


GO

