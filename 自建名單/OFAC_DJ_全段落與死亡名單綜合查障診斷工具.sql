/*
========================================================================================
腳本名稱：OFAC_DJ_全段落與死亡名單綜合查障診斷工具.sql
主要定位：全方位單點問題排查工具 (純查詢，無寫入風險)
涵蓋範圍：
  1. 第 1 段：主要制裁名單 (Primary Name，GROUPID = @GroupId_Sec1)
  2. 第 2 段：制裁控制與實質所有權 (SCO，固定 GROUPID = 27)
  3. 第 3 段：制裁證件識別號 (Sanctions IDs，固定 GROUPID = 10)
  4. 第 4 段：日本金融制裁名單 (Japanese Finance，跨庫 BSADBJP..OFAC_SPEC，GROUPID = 5)
  5. 死亡名單專屬檢測 (Deceased = 1 狀態與關聯制裁判定)

[使用時機]
User 或業務詢問「為什麼 DJ 有這筆資料，但系統查不到 / 沒有命中？」時，
填入查詢條件後整支執行，即可一次看完全部段落的命中與卡控原因。
========================================================================================
*/

-- -------------------------------------------------------------------------------------
-- 設定查詢條件 (支援 姓名/實體名稱、DJ 實體編號、證件號碼)
-- -------------------------------------------------------------------------------------
DECLARE @QueryName     NVARCHAR(350) = 'PUTIN';  -- 填入查詢姓名/公司名稱 (留空則不限制)
DECLARE @QueryEntNum   BIGINT        = NULL;     -- 填入 DJ 實體編號 EntNum (留 NULL 則不限制)
DECLARE @QueryIDNumber NVARCHAR(350) = NULL;     -- 填入 證件號/護照號/稅號/Email (查詢第3段用)
DECLARE @GroupId_Sec1  BIGINT        = 1;        -- 第 1 段指定比對的 GroupId


-- =====================================================================================
-- 【區塊 0】死亡名單狀態檢視 (Deceased 專屬檢測)
-- =====================================================================================
SELECT 
    '0. 死亡名單狀態' AS Check_Section,
    E.EntityId AS EntNum,
    E.FullName AS Entity_FullName,
    E.PersonStatus,
    CASE 
        WHEN E.Deceased = 1 THEN '是 (Deceased 等於 1，DJ 標記為身故)'
        ELSE '否 (Deceased 為 0 或 NULL，DJ 未標記身故)'
    END AS Deceased_Status,
    CASE 
        WHEN REF.SanctionReferences LIKE '%Japanese Finance%' THEN '包含 Japanese Finance (符合第4段死亡名單納入條件)'
        ELSE '未包含 Japanese Finance (不符合第4段死亡擴大掃描)'
    END AS JP_Finance_Ref_Status,
    REF.SanctionReferences AS All_Sanctions_References
FROM BSADB.dbo.DJ_Entity E WITH (NOLOCK)
OUTER APPLY (
    SELECT STUFF((
        SELECT ';' + R.SanctionListReference
        FROM BSADB.dbo.DJ_SanctionListReference R WITH (NOLOCK)
        WHERE R.EntityId = E.EntityId
        FOR XML PATH(''), TYPE
    ).value('.', 'nvarchar(max)'), 1, 1, '') AS SanctionReferences
) REF
WHERE (@QueryEntNum IS NOT NULL AND E.EntityId = @QueryEntNum)
   OR (@QueryName IS NOT NULL AND E.FullName LIKE '%' + @QueryName + '%');


-- =====================================================================================
-- 【區塊 1】第 1 段：主要制裁人名 (Primary Name，GROUPID = @GroupId_Sec1)
-- =====================================================================================
SELECT 
    '1. 主要制裁名單 (Sec 1)' AS Check_Section,
    ISNULL(DJ.EntNum, CAST(T.remark AS BIGINT)) AS EntNum,
    ISNULL(DJ.SdnName, T.spec_name)             AS Name_Or_Entity,

    -- 來源條件診斷
    CASE 
        WHEN DJ.EntNum IS NULL THEN 'DJ 來源無此人'
        WHEN DJ.NamePropertyBitCode & 1 = 0 THEN '未命中：非 Primary Name (屬於 Alias/別名，第1段排除)'
        ELSE '來源端條件符合 (Primary Name)'
    END AS Source_Status,

    -- 主表狀態診斷
    CASE 
        WHEN T.spec_name IS NULL THEN '主表無此筆 (未同步)'
        WHEN T.DInd = 'Y' THEN '已同步但為「軟刪除停用 (DInd=Y)」'
        WHEN T.DInd = 'N' THEN '主表正常生效中 (DInd=N)'
    END AS Target_Table_Status,

    T.GROUPID         AS Target_GroupId,
    T.updated_date    AS Internal_UpdatedDate,
    T.delDt           AS Internal_DelDate

FROM (
    SELECT EntNum, SdnName, NamePropertyBitCode, UpdatedDate
    FROM BSADB.dbo.DJ_List_Data_A WITH (NOLOCK)
    WHERE (@QueryEntNum IS NOT NULL AND EntNum = @QueryEntNum)
       OR (@QueryName IS NOT NULL AND SdnName LIKE '%' + @QueryName + '%')
) DJ
FULL OUTER JOIN (
    SELECT *
    FROM BSADB.dbo.OFAC_GLSpec WITH (NOLOCK)
    WHERE GROUPID = @GroupId_Sec1
      AND (
          (@QueryEntNum IS NOT NULL AND remark = CAST(@QueryEntNum AS VARCHAR(100)))
       OR (@QueryName IS NOT NULL AND spec_name LIKE '%' + @QueryName + '%')
      )
) T ON T.spec_name = DJ.SdnName AND T.remark = CAST(DJ.EntNum AS VARCHAR(100));


-- =====================================================================================
-- 【區塊 2】第 2 段：制裁控制與實質所有權 (SCO，GROUPID = 27)
-- =====================================================================================
SELECT 
    '2. SCO實質所有權 (Sec 2)' AS Check_Section,
    ISNULL(S.EntNum, CAST(T.remark AS BIGINT)) AS EntNum,
    ISNULL(S.SdnName, T.spec_name)             AS Name_Or_Entity,

    -- 來源條件診斷
    CASE 
        WHEN S.EntNum IS NULL THEN 'DJ 來源無此實體'
        WHEN S.PersonStatus = 'Inactive' THEN '未命中：實體狀態為 Inactive'
        WHEN S.HasValidSCOCategory = 0 THEN '未命中：不屬於 OFAC/EU Majority Owned 或 Control 分類'
        WHEN S.IsOSN = 1 THEN '未命中：名稱次類型為 OSN (NameSubType=OSN 排除)'
        ELSE '來源端條件符合 (SCO 名單)'
    END AS Source_Status,

    -- 主表狀態診斷 (GROUPID = 27)
    CASE 
        WHEN T.spec_name IS NULL THEN '主表 GROUPID=27 無此筆 (未同步)'
        WHEN T.DInd = 'Y' THEN '主表存在但為「軟刪除停用 (DInd=Y)」'
        WHEN T.DInd = 'N' THEN '主表正常生效中 (DInd=N)'
    END AS Target_Table_Status,

    T.updated_date AS Internal_UpdatedDate,
    T.ADDRESS      AS Internal_SanctionListRef

FROM (
    SELECT 
        A.EntityId AS EntNum,
        C.SdnName,
        A.PersonStatus,
        CASE 
            WHEN EXISTS (
                SELECT 1 FROM BSADB.dbo.DJ_ListCategory B WITH (NOLOCK)
                WHERE B.EntityId = A.EntityId 
                  AND B.Deleted = 0
                  AND B.Description3 IN (
                    'OFAC Related - Majority Owned',
                    'OFAC Related – Control',
                    'OFAC - Regional Sanctions Related - Majority Owned',
                    'OFAC - Regional Sanctions Related - Control',
                    'EU Related - Majority Owned',
                    'EU Related - Control',
                    'EU - Regional Sanctions Related - Majority Owned',
                    'EU - Regional Sanctions Related – Control'
                  )
            ) THEN 1 ELSE 0 
        END AS HasValidSCOCategory,
        CASE WHEN ISNULL(D.NameSubType, '') = 'OSN' THEN 1 ELSE 0 END AS IsOSN
    FROM BSADB.dbo.DJ_Entity A WITH (NOLOCK)
    JOIN BSADB.dbo.DJ_List_Data_A C WITH (NOLOCK) ON A.EntityId = C.EntNum
    LEFT JOIN BSADB.dbo.DJ_AltName D WITH (NOLOCK) ON C.EntNum = D.EntityId AND C.AltNum = D.AltNameId
    WHERE (@QueryEntNum IS NOT NULL AND A.EntityId = @QueryEntNum)
       OR (@QueryName IS NOT NULL AND C.SdnName LIKE '%' + @QueryName + '%')
) S
FULL OUTER JOIN (
    SELECT *
    FROM BSADB.dbo.OFAC_GLSpec WITH (NOLOCK)
    WHERE GROUPID = 27
      AND (
          (@QueryEntNum IS NOT NULL AND remark = CAST(@QueryEntNum AS VARCHAR(100)))
       OR (@QueryName IS NOT NULL AND spec_name LIKE '%' + @QueryName + '%')
      )
) T ON T.spec_name = S.SdnName AND T.remark = CAST(S.EntNum AS VARCHAR(100));


-- =====================================================================================
-- 【區塊 3】第 3 段：制裁證件識別號 (Sanctions IDs，GROUPID = 10)
-- =====================================================================================
SELECT 
    '3. Sanctions IDs (Sec 3)' AS Check_Section,
    ISNULL(S.EntityId, CAST(T.remark AS BIGINT)) AS EntNum,
    ISNULL(S.IdentificationNumber, T.spec_name)  AS IdentNumber_In_SpecName,
    S.IdentificationType,

    -- 來源條件診斷
    CASE 
        WHEN S.EntityId IS NULL THEN 'DJ 未找到此證件/號碼'
        WHEN S.PersonStatus = 'Inactive' THEN '未命中：實體狀態為 Inactive'
        WHEN S.HasValidCategory = 0 THEN '未命中：分類不符 Sanctions Lists 或關聯條件'
        WHEN S.TypeAllowed = 0 THEN '未命中：證件類型不在允許的 19 種清單內'
        WHEN S.IdentDeleted = 1 THEN '未命中：證件已被標記 Deleted=1'
        ELSE '來源端條件符合 (Sanctions ID)'
    END AS Source_Status,

    -- 主表狀態診斷 (GROUPID = 10)
    CASE 
        WHEN T.spec_name IS NULL THEN '主表 GROUPID=10 無此筆 (未同步)'
        WHEN T.DInd = 'Y' THEN '主表存在但為「軟刪除停用 (DInd=Y)」'
        WHEN T.DInd = 'N' THEN '主表正常生效中 (DInd=N)'
    END AS Target_Table_Status,

    T.updated_date AS Internal_UpdatedDate,
    T.ADDRESS      AS Internal_Address_IdentType

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
       OR (@QueryName IS NOT NULL AND EXISTS (
            SELECT 1 FROM BSADB.dbo.DJ_List_Data_A N 
            WHERE N.EntNum = A.EntityId AND N.SdnName LIKE '%' + @QueryName + '%'
       ))
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
       OR (@QueryName IS NOT NULL AND spec_name LIKE '%' + @QueryName + '%')
      )
) T 
    ON T.spec_name = S.IdentificationNumber
   AND T.remark = CAST(S.EntityId AS VARCHAR(100))
   AND T.ExtractedIdentType = S.IdentificationType;


-- =====================================================================================
-- 【區塊 4】第 4 段：日本金融制裁名單 (Japanese Finance，跨庫 BSADBJP，GROUPID = 5)
-- =====================================================================================
SELECT 
    '4. 日本金融制裁 (Sec 4)' AS Check_Section,
    ISNULL(S.EntNum, CAST(T.remark AS BIGINT)) AS EntNum,
    ISNULL(S.SdnName, T.spec_name)             AS Name_Or_Entity,

    -- 來源條件診斷 (含死亡名單雙軌檢測)
    CASE 
        WHEN S.EntNum IS NULL THEN 'DJ 來源無此人'
        WHEN S.HasJPReference = 0 THEN '未命中：未包含 Japanese Finance 關鍵字'
        WHEN S.NamePropertyBitCode & 1 = 0 AND S.Deceased = 0 THEN '未命中：非主要姓名且非身故實體 (Deceased=0)'
        ELSE '來源端條件符合 (日本金融制裁)'
    END AS Source_Status,

    S.Deceased AS Is_Deceased,

    -- 日本主表狀態診斷 (BSADBJP..OFAC_SPEC, GROUPID = 5)
    CASE 
        WHEN T.spec_name IS NULL THEN '日本主表無此筆 (未同步)'
        WHEN T.DInd = 'Y' THEN '日本主表存在但為「軟刪除停用 (DInd=Y)」'
        WHEN T.DInd = 'N' THEN '日本主表正常生效中 (DInd=N)'
    END AS Target_Table_Status,

    T.ent_num      AS Target_ent_num,
    T.updated_date AS Internal_UpdatedDate,
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
