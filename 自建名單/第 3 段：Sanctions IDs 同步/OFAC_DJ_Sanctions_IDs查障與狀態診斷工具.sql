當 User 或業務詢問 「為什麼某個證件號/護照號/稅號在 DJ 有，但在系統主表（GROUPID = 10）查不到？」 時使用。

/*
========================================================================================
腳本名稱：OFAC_DJ_Sanctions_IDs查障與狀態診斷工具.sql
主要定位：第 3 段 Sanctions IDs (GROUPID = 10) 專用客服與單點排查工具 (純查詢無副作用)
說明：
  User 詢問「為什麼某個證件號碼、稅號、護照號或 Email 在 DJ 存在，但系統主表查不到？」時使用。
========================================================================================
*/

-- -------------------------------------------------------------------------------------
-- 設定查詢條件：請填入欲查詢的 證件/識別號碼 或 DJ 實體編號
-- -------------------------------------------------------------------------------------
DECLARE @QueryIDNumber NVARCHAR(350) = '12345678'; -- 填入查詢的證件號/護照號/稅號/Email等
DECLARE @QueryEntNum   BIGINT        = NULL;       -- 填入 DJ 實體編號 (留 NULL 則不限制)


-- -------------------------------------------------------------------------------------
-- 診斷 1：全局健檢，檢視 Sanctions IDs 篩選條件與主表狀態 (GROUPID = 10)
-- -------------------------------------------------------------------------------------
SELECT 
    ISNULL(S.EntityId, CAST(T.remark AS BIGINT)) AS EntNum,
    ISNULL(S.IdentificationNumber, T.spec_name)  AS IdentNumber_In_SpecName,
    S.IdentificationType,

    -- 1. 來源端過濾條件檢視
    CASE 
        WHEN S.EntityId IS NULL THEN 'DJ 未找到此號碼'
        WHEN S.PersonStatus = 'Inactive' THEN '實體狀態為 Inactive，被排除'
        WHEN S.HasValidCategory = 0 THEN '所屬名單分類不符合 Sanctions Lists 或 OFAC/EU 關聯條件'
        WHEN S.TypeAllowed = 0 THEN '證件類型不在允許的 19 種清單中'
        WHEN S.IdentDeleted = 1 THEN '證件已被標記 Deleted 等於 1'
        ELSE '來源端條件完全符合'
    END AS Source_Condition_Status,

    -- 2. 內部主表狀態檢視
    CASE 
        WHEN T.spec_name IS NULL THEN '主表 GROUPID=10 找不到此筆'
        WHEN T.DInd = 'Y' THEN '主表已停用軟刪除 (DInd=Y)'
        WHEN T.DInd = 'N' THEN '主表正常生效中 (DInd=N)'
    END AS Target_Table_Status,

    T.updated_date AS Internal_UpdatedDate,
    T.creDate      AS Internal_CreateDate,
    T.DelDate      AS Internal_DelDate

FROM (
    SELECT 
        A.EntityId,
        A.PersonStatus,
        D.IdentificationType,
        D.IdentificationNumber,
        D.Deleted AS IdentDeleted,
        CASE 
            WHEN EXISTS (
                SELECT 1 FROM BSADB.dbo.DJ_ListCategory B WITH (NOLOCK)
                WHERE B.EntityId = A.EntityId 
                  AND B.Deleted = 0
                  AND (
                        B.Description2 = 'Sanctions Lists'
                     OR B.Description3 IN (
                            'OFAC Related - Majority Owned',
                            'OFAC Related - Control',
                            'OFAC - Regional Sanctions Related - Majority Owned',
                            'OFAC - Regional Sanctions Related - Control',
                            'EU Related - Majority Owned',
                            'EU Related - Control',
                            'EU - Regional Sanctions Related - Majority Owned',
                            'EU - Regional Sanctions Related - Control'
                        )
                  )
            ) THEN 1 ELSE 0 
        END AS HasValidCategory,
        CASE 
            WHEN D.IdentificationType IN (
                'Aircraft Construction, Line, Fleet or Serial Number',
                'Aircraft Manufacturer''s Serial Number (MSN)',
                'Bank Identifier Code (BIC)',
                'Central Registration Depository (CRD)',
                'Company Identification No.',
                'Driving Licence No.',
                'DUNS Number',
                'International Maritime Organization (IMO) Ship No.',
                'International Securities Identification Number (ISIN)',
                'Legal Entity Identifier (LEI)',
                'National ID',
                'National Provider Identifier (NPI)',
                'National Tax No.',
                'Others',
                'Passport No.',
                'Social Security No.',
                'Email',
                'Fax',
                'Phone'
            ) THEN 1 ELSE 0 
        END AS TypeAllowed
    FROM BSADB.dbo.DJ_Entity A WITH (NOLOCK)
    JOIN BSADB.dbo.DJ_IdentificationTypeInfo D WITH (NOLOCK) ON A.EntityId = D.EntityId
    WHERE (@QueryEntNum IS NOT NULL AND A.EntityId = @QueryEntNum)
       OR (@QueryIDNumber IS NOT NULL AND D.IdentificationNumber = @QueryIDNumber)
) S
FULL OUTER JOIN (
    SELECT 
        *,
        REPLACE(ADDRESS, '; Please go to Dowjones website for more detail', '') AS ExtractedIdentType
    FROM BSADB.dbo.OFAC_GLSpec WITH (NOLOCK)
    WHERE GROUPID = 10
      AND (
          (@QueryEntNum IS NOT NULL AND remark = CAST(@QueryEntNum AS VARCHAR(100)))
       OR (@QueryIDNumber IS NOT NULL AND spec_name = @QueryIDNumber)
      )
) T 
    ON T.spec_name = S.IdentificationNumber
   AND T.remark = CAST(S.EntityId AS VARCHAR(100))
   AND T.ExtractedIdentType = S.IdentificationType;


-- -------------------------------------------------------------------------------------
-- 診斷 2：調閱該證件號碼在 Log 表中的異動歷史 (GROUPID = 10)
-- -------------------------------------------------------------------------------------
SELECT 
    ActionDt,
    CASE ActionCD 
        WHEN '01' THEN '01 - 新增 / 重新啟用'
        WHEN '02' THEN '02 - 資料更新'
        WHEN '03' THEN '03 - 軟刪除 (停用)'
    END AS ActionType,
    ent_num,
    spec_name AS IdentNumber_SpecName,
    remark    AS EntNum,
    DInd,
    updated_date,
    ADDRESS
FROM BSADB.dbo.OFAC_GLSpec_Log WITH (NOLOCK)
WHERE GROUPID = 10
  AND (
      (@QueryEntNum IS NOT NULL AND remark = CAST(@QueryEntNum AS VARCHAR(100)))
   OR (@QueryIDNumber IS NOT NULL AND spec_name = @QueryIDNumber)
  )
ORDER BY ActionDt DESC;
