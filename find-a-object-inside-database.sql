SELECT DISTINCT
     o.name AS Object_Name,
     o.type_desc,
	   c.text
  FROM sys.sql_modules m
     INNER JOIN sys.objects o ON m.object_id = o.object_id
	   INNER JOIN sys.syscomments c ON c.id = o.object_id
 WHERE m.definition Like '%YOUR_TEXT_HERE%';
