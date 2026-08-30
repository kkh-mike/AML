/*

當 User 問 「為什麼某人或某機構在日本金融制裁名單，但在日本主表（BSADBJP..OFAC_SPEC, GROUPID = 5）查不到？」 時使用。

========================================================================================
腳本名稱：OFAC_JP_日本金融名單查障與狀態診斷工具.sql
主要定位：第 4 段 日本金融制裁名單 (GROUPID = 5) 專用客服與單點排查工具 (純查詢無副作用)
說明：
  User 詢問「為什麼某人或實體在 DJ 為日本金融制裁對象，但主表 BSADBJP..OFAC_SPEC 查不到？」時使用。
========================================================================================
*/

-- -------------------------------------------------------------------------------------
-- 設定查詢條件 (支援 姓名/實體名稱 或 EntNum)
-- -------------------------------------------------------------------------------------
DECLARE @QueryName   NVARCHAR(350) = 'YAMADA'; -- 填入欲查詢之姓名或公司名稱
DECLARE @QueryEntNum BIGINT        = NULL;     -- 填入 DJ 實體編號 (留 NULL 則不限制)


-- -------------------------------------------------------------------------------------
-- 診斷 1：全局健檢，檢視日本金融制裁篩選條件與主表狀態 (BSADBJP..OFAC_SPEC, GROUPID = 5)
-- -------------------------------------------------------------------------------------
SELECT 
    ISNULL(S.EntNum, CAST(T.remark AS BIGINT)) AS EntNum,
    ISNULL(S.SdnName, T.spec_name)             AS PersonOrEntityName,

    -- 1. 日本名單來源端條件診斷
    CASE 
        WHEN S.EntNum IS NULL THEN 'DJ 來源無此資料'
        WHEN S.HasJPReference = 0 THEN 'SanctionListReference 未包含 Japanese Finance 關鍵字'
        WHEN S.NamePropertyBitCode & 1 = 0 AND S.Deceased = 0 THEN '非主要姓名 (BitCode排除) 且非身故實體 (Deceased=0)'
        ELSE '來源端完全符合日本金融制裁條件'
    END AS JP_Source_Condition_Status,

    S.Deceased             AS IsDeceased,
    S.HasJPReference       AS HasJPFinanceRef,

    -- 2. 內部主表狀態診斷 (BSADBJP..OFAC_SPEC, GROUPID = 5)
    CASE 
        WHEN T.spec_name IS NULL THEN '主表 BSADBJP..OFAC_SPEC 找不到此筆'
        WHEN T.DInd = 'Y' THEN '主表存在但「已軟刪除停用 (DInd=Y)」'
        WHEN T.DInd = 'N' THEN '主表正常生效中 (DInd=N)'
    END AS Target_Table_Status,

    T.ent_num      AS Target_ent_num,
    T.updated_date AS Internal_UpdatedDate,
    T.creDate      AS Internal_CreateDate,
    T.DelDate      AS Internal_DelDate

FROM (
    SELECT 
        A.EntityId AS EntNum,
        ISNULL(C.SdnName, A.FullName) AS SdnName,
        A.Deceased,
        ISNULL(C.NamePropertyBitCode, 0) AS NamePropertyBitCode,
        CASE 
            WHEN EXISTS (
                SELECT 1 FROM BSADB.dbo.DJ_SanctionListReference B WITH (NOLOCK)
                WHERE B.EntityId = A.EntityId 
                  AND B.SanctionListReference LIKE '%Japanese Finance%'
            ) THEN 1 ELSE 0 
        END AS HasJPReference
    FROM BSADB.dbo.DJ_Entity A WITH (NOLOCK)
    LEFT JOIN BSADB.dbo.DJ_List_Data_A C WITH (NOLOCK) ON A.EntityId = C.EntNum
    WHERE (@QueryEntNum IS NOT NULL AND A.EntityId = @QueryEntNum)
       OR (@QueryName IS NOT NULL AND (C.SdnName LIKE '%' + @QueryName + '%' OR A.FullName LIKE '%' + @QueryName + '%'))
) S
FULL OUTER JOIN (
    SELECT *
    FROM BSADBJP..OFAC_SPEC WITH (NOLOCK)
    WHERE GROUPID = 5
      AND (
          (@QueryEntNum IS NOT NULL AND remark = CAST(@QueryEntNum AS VARCHAR(100)))
       OR (@QueryName IS NOT NULL AND spec_name LIKE '%' + @QueryName + '%')
      )
) T ON T.spec_name = S.SdnName AND T.remark = CAST(S.EntNum AS VARCHAR(100));


-- -------------------------------------------------------------------------------------
-- 診斷 2：調閱該實體在日本 Log 表中的異動歷史 (BSADBJP.dbo.OFAC_SPEC_LOG)
-- -------------------------------------------------------------------------------------
SELECT 
    ActionDT,
    ActionDT_UTC,
    CASE ActionCD 
        WHEN '01' THEN '01 - 新增 / 重新啟用'
        WHEN '02' THEN '02 - 資料更新'
        WHEN '03' THEN '03 - 軟刪除 (停用)'
    END AS ActionType,
    ent_num,
    spec_name,
    remark AS EntNum,
    DInd,
    updated_date,
    IssBy,
    SOURCE
FROM BSADBJP.dbo.OFAC_SPEC_LOG WITH (NOLOCK)
WHERE GROUPID = 5
  AND (
      (@QueryEntNum IS NOT NULL AND remark = CAST(@QueryEntNum AS VARCHAR(100)))
   OR (@QueryName IS NOT NULL AND spec_name LIKE '%' + @QueryName + '%')
  )
ORDER BY ActionDT DESC;
