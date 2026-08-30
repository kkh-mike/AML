/*
========================================================================================
腳本名稱：OFAC_DJ_死亡名單未命中查障與狀態診斷工具.sql
主要定位：死亡名單 (Deceased = 1) 專用客服與單點排查工具 (純查詢無副作用)
查詢目標：BSADB.dbo.DJ_Entity, BSADB.dbo.DJ_SanctionListReference, BSADBJP..OFAC_SPEC, BSADB.dbo.OFAC_GLSpec

[適用對象]
一線維運人員、客服工程師、系統管理者

[使用時機]
1. User 詢問：「為什麼此人是死亡名單，但系統卻沒有命中或查不到？」
2. 需要撈出 DJ 來源目前所有被標記為死亡名單的實體資料。
3. 確認某個身故實體在各個 GroupId（如 GroupId=5 日本名單、GroupId=1 主名單）的同步狀態。
========================================================================================
*/

-- -------------------------------------------------------------------------------------
-- 設定查詢條件：支援 姓名 或 DJ 實體編號
-- -------------------------------------------------------------------------------------
DECLARE @QueryName   NVARCHAR(350) = 'ABE'; -- 填入查詢姓名 (支援模糊比對，留空則查全部)
DECLARE @QueryEntNum BIGINT        = NULL;  -- 填入 DJ 實體編號 (留 NULL 則不限制)


-- -------------------------------------------------------------------------------------
-- 工具 1：【全量檢索】如何撈出 DJ 來源中所有的死亡名單實體 (含其制裁參考與主要姓名)
-- -------------------------------------------------------------------------------------
SELECT 
    E.EntityId AS EntNum,
    E.FullName AS DJ_Entity_FullName,
    L.SdnName  AS DJ_Primary_SdnName,
    E.PersonStatus,
    E.Deceased,
    E.UpdatedDate_UTC,
    REF.SanctionReferences
FROM BSADB.dbo.DJ_Entity E WITH (NOLOCK)
LEFT JOIN (
    -- 取得主要姓名 (BitCode & 1 > 0)
    SELECT EntNum, SdnName
    FROM BSADB.dbo.DJ_List_Data_A WITH (NOLOCK)
    WHERE NamePropertyBitCode & 1 > 0
) L ON E.EntityId = L.EntNum
OUTER APPLY (
    -- 聚合所有制裁清單參考資訊
    SELECT STUFF((
        SELECT ';' + R.SanctionListReference
        FROM BSADB.dbo.DJ_SanctionListReference R WITH (NOLOCK)
        WHERE R.EntityId = E.EntityId
        FOR XML PATH(''), TYPE
    ).value('.', 'nvarchar(max)'), 1, 1, '') AS SanctionReferences
) REF
WHERE E.Deceased = 1 -- 關鍵條件：標記為死亡名單
  AND (@QueryEntNum IS NULL OR E.EntityId = @QueryEntNum)
  AND (@QueryName IS NULL OR E.FullName LIKE '%' + @QueryName + '%' OR L.SdnName LIKE '%' + @QueryName + '%');


-- -------------------------------------------------------------------------------------
-- 工具 2：【深度診斷】為什麼「特定死亡名單」在系統主表查不到？(逐項檢查卡控條件)
-- -------------------------------------------------------------------------------------
SELECT 
    ISNULL(E.EntityId, CAST(T_JP.remark AS BIGINT)) AS EntNum,
    ISNULL(E.FullName, T_JP.spec_name)              AS EntityName,
    
    -- 1. 死亡狀態檢查
    CASE 
        WHEN E.EntityId IS NULL THEN 'DJ 來源無此實體'
        WHEN E.Deceased = 1 THEN '是 (Deceased 等於 1)'
        ELSE '否 (Deceased 為 0 或 NULL，DJ 未標記為死亡)'
    END AS Is_Deceased_Status,

    -- 2. 日本金融制裁 (Japanese Finance) 條件檢查
    CASE 
        WHEN REF.HasJPFinanceRef = 1 THEN '符合 (包含 Japanese Finance 關鍵字)'
        ELSE '不符合 (未包含 Japanese Finance，不會進 GroupId 5)'
    END AS JP_Finance_Ref_Status,

    -- 3. 日本主表同步狀態 (BSADBJP..OFAC_SPEC, GROUPID = 5)
    CASE 
        WHEN T_JP.spec_name IS NULL THEN '日本主表查無此筆 (未同步)'
        WHEN T_JP.DInd = 'Y' THEN '日本主表已停用 (DInd=Y)'
        WHEN T_JP.DInd = 'N' THEN '日本主表正常生效中 (DInd=N)'
    END AS JP_Table_Status_GroupId_5,

    -- 4. 總部主表同步狀態 (BSADB.dbo.OFAC_GLSpec, GROUPID = 1 主名單)
    CASE 
        WHEN T_GL.spec_name IS NULL THEN '總部主表查無此筆'
        WHEN T_GL.DInd = 'Y' THEN '總部主表已停用 (DInd=Y)'
        WHEN T_GL.DInd = 'N' THEN '總部主表正常生效中 (DInd=N)'
    END AS Global_Table_Status_GroupId_1,

    REF.All_SanctionListReferences AS SanctionReferences_Detail

FROM (
    SELECT EntityId, FullName, Deceased, PersonStatus, UpdatedDate_UTC
    FROM BSADB.dbo.DJ_Entity WITH (NOLOCK)
    WHERE (@QueryEntNum IS NOT NULL AND EntityId = @QueryEntNum)
       OR (@QueryName IS NOT NULL AND FullName LIKE '%' + @QueryName + '%')
) E
OUTER APPLY (
    SELECT 
        MAX(CASE WHEN R.SanctionListReference LIKE '%Japanese Finance%' THEN 1 ELSE 0 END) AS HasJPFinanceRef,
        STUFF((
            SELECT ';' + R.SanctionListReference
            FROM BSADB.dbo.DJ_SanctionListReference R WITH (NOLOCK)
            WHERE R.EntityId = E.EntityId
            FOR XML PATH(''), TYPE
        ).value('.', 'nvarchar(max)'), 1, 1, '') AS All_SanctionListReferences
    FROM BSADB.dbo.DJ_SanctionListReference R WITH (NOLOCK)
    WHERE R.EntityId = E.EntityId
) REF
-- 比對日本主表 (GroupId = 5)
LEFT JOIN BSADBJP..OFAC_SPEC T_JP WITH (NOLOCK)
    ON T_JP.GROUPID = 5
   AND (T_JP.remark = CAST(E.EntityId AS VARCHAR(100)) OR T_JP.spec_name = E.FullName)
-- 比對總部主表 (GroupId = 1)
LEFT JOIN BSADB.dbo.OFAC_GLSpec T_GL WITH (NOLOCK)
    ON T_GL.GROUPID = 1
   AND (T_GL.remark = CAST(E.EntityId AS VARCHAR(100)) OR T_GL.spec_name = E.FullName);


-- -------------------------------------------------------------------------------------
-- 工具 3：【名單分類追查】確認該實體所屬的 DJ 分類 (BL / PEP / NN) 與是否包含有效制裁
-- -------------------------------------------------------------------------------------
SELECT 
    A.EntityId AS EntNum,
    A.FullName,
    A.Deceased,
    C.Description1 AS Category_Level1,
    C.Description2 AS Category_Level2,
    C.Description3 AS Category_Level3,
    C.Deleted      AS Category_Deleted
FROM BSADB.dbo.DJ_Entity A WITH (NOLOCK)
LEFT JOIN BSADB.dbo.DJ_ListCategory C WITH (NOLOCK) ON A.EntityId = C.EntityId
WHERE A.Deceased = 1
  AND (
      (@QueryEntNum IS NOT NULL AND A.EntityId = @QueryEntNum)
   OR (@QueryName IS NOT NULL AND A.FullName LIKE '%' + @QueryName + '%')
  );
