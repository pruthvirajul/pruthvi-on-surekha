const express = require('express');
const { Pool } = require('pg');
const cors = require('cors');
require('dotenv').config();

const app = express();
const port = process.env.PORT || 3697;

// PostgreSQL connection
const pool = new Pool({
    user: process.env.DB_USER || 'postgres',
    host: process.env.DB_HOST || 'postgres',
    database: process.env.DB_NAME || 'onboarding_system',
    password: process.env.DB_PASSWORD || 'admin321',
    port: process.env.DB_PORT || 5432,
});

app.use(cors());
app.use(express.json({ limit: '10mb' }));

// Middleware to handle errors
const errorHandler = (err, req, res, next) => {
    console.error(err.stack);
    res.status(500).json({ error: err.message || 'Internal Server Error' });
};

// Calculate progress
const calculateProgress = (data) => {
    const totalSections = 5;
    let completedSections = 0;
    if (data.personal_details?.firstName && data.personal_details?.email) completedSections++;
    if (data.educational_details?.length > 0) completedSections++;
    if (data.bank_details?.accountNumber) completedSections++;
    if (data.id_uploads && Object.keys(data.id_uploads).length > 0) completedSections++;
    if (data.is_fresher || data.previous_company?.length > 0) completedSections++;
    return Math.round((completedSections / totalSections) * 100);
};

// Add or update employee
app.post('/api/employees', async (req, res, next) => {
    const client = await pool.connect();
    try {
        await client.query('BEGIN');
        const { personalDetails, bankDetails, idUploads, isFresher, educationalDetails, previousCompany } = req.body;

        // Map camelCase to snake_case for database
        const personal_details = personalDetails;
        const bank_details = bankDetails;
        const id_uploads = idUploads;
        const is_fresher = isFresher;
        const email = personalDetails.email;
        const progress = calculateProgress({
            personal_details,
            bank_details,
            id_uploads,
            is_fresher,
            educational_details: educationalDetails,
            previous_company: previousCompany
        });

        // Insert employee
        const employeeResult = await client.query(
            'INSERT INTO employees (personal_details, bank_details, id_uploads, is_fresher, email, progress) VALUES ($1, $2, $3, $4, $5, $6) RETURNING *',
            [personal_details, bank_details, id_uploads, is_fresher, email, progress]
        );
        let employee = employeeResult.rows[0];

        // Insert educational details
        for (const edu of educationalDetails || []) {
            if (edu.educationType) {
                await client.query(
                    'INSERT INTO educational_details (employee_id, education_type, institution_name, branch, passout_year, percentage, location, certificate) VALUES ($1, $2, $3, $4, $5, $6, $7, $8)',
                    [employee.id, edu.educationType, edu.institutionName, edu.branch, edu.passoutYear, edu.percentage, edu.location, edu.certificate]
                );
            }
        }

        // Insert previous employment
        if (!is_fresher) {
            for (const job of previousCompany || []) {
                if (job.companyName) {
                    await client.query(
                        'INSERT INTO previous_employment (employee_id, company_name, designation, experience, start_date, end_date, location, relieving_letter, experience_letter) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)',
                        [employee.id, job.companyName, job.designation, job.experience, job.startDate, job.endDate, job.location, job.relievingLetter, job.experienceLetter]
                    );
                }
            }
        }

        // Fetch complete employee data
        const completeResult = await client.query(
            `SELECT e.*, 
                (SELECT json_agg(ed) FROM educational_details ed WHERE ed.employee_id = e.id) as educational_details,
                (SELECT json_agg(pe) FROM previous_employment pe WHERE pe.employee_id = e.id) as previous_company
             FROM employees e WHERE e.id = $1`,
            [employee.id]
        );
        employee = completeResult.rows[0];

        await client.query('COMMIT');
        res.status(201).json(employee); // Return as-is without toCamelCase
    } catch (err) {
        await client.query('ROLLBACK');
        next(err);
    } finally {
        client.release();
    }
});

// Get all employees
app.get('/api/employees', async (req, res, next) => {
    try {
        const result = await pool.query(
            `SELECT e.*, 
                (SELECT json_agg(ed) FROM educational_details ed WHERE ed.employee_id = e.id) as educational_details,
                (SELECT json_agg(pe) FROM previous_employment pe WHERE pe.employee_id = e.id) as previous_company
             FROM employees e`
        );
        res.json(result.rows);
    } catch (err) {
        next(err);
    }
});

// Get employee by ID
app.get('/api/employees/:id', async (req, res, next) => {
    try {
        console.log(`Fetching employee with ID: ${req.params.id}`);
        const result = await pool.query(
            `SELECT e.*, 
                (SELECT json_agg(ed) FROM educational_details ed WHERE ed.employee_id = e.id) as educational_details,
                (SELECT json_agg(pe) FROM previous_employment pe WHERE pe.employee_id = e.id) as previous_company
             FROM employees e WHERE e.id = $1`,
            [req.params.id]
        );
        if (result.rows.length === 0) {
            console.log(`No employee found with ID: ${req.params.id}`);
            return res.status(404).json({ error: 'Employee not found' });
        }
        res.json(result.rows[0]);
    } catch (err) {
        next(err);
    }
});

// Update employee status
app.patch('/api/employees/:id/status', async (req, res, next) => {
    try {
        const { status } = req.body;
        if (!['Approved', 'Rejected'].includes(status)) {
            return res.status(400).json({ error: 'Invalid status' });
        }
        const result = await pool.query(
            'UPDATE employees SET status = $1, last_updated = CURRENT_TIMESTAMP WHERE id = $2 RETURNING *',
            [status, req.params.id]
        );
        if (result.rows.length === 0) {
            return res.status(404).json({ error: 'Employee not found' });
        }
        res.json(result.rows[0]);
    } catch (err) {
        next(err);
    }
});

// Delete employee
app.delete('/api/employees/:id', async (req, res, next) => {
    const client = await pool.connect();
    try {
        await client.query('BEGIN');
        await client.query('DELETE FROM educational_details WHERE employee_id = $1', [req.params.id]);
        await client.query('DELETE FROM previous_employment WHERE employee_id = $1', [req.params.id]);
        const deleteEmployee = await client.query('DELETE FROM employees WHERE id = $1 RETURNING *', [req.params.id]);
        if (deleteEmployee.rowCount === 0) {
            await client.query('ROLLBACK');
            return res.status(404).json({ error: 'Employee not found' });
        }
        await client.query('COMMIT');
        res.status(204).send();
    } catch (err) {
        await client.query('ROLLBACK');
        next(err);
    } finally {
        client.release();
    }
});

// Search employees
app.get('/api/employees/search/:term', async (req, res, next) => {
    try {
        const term = `%${req.params.term}%`;
        const result = await pool.query(
            `SELECT e.*, 
                (SELECT json_agg(ed) FROM educational_details ed WHERE ed.employee_id = e.id) as educational_details,
                (SELECT json_agg(pe) FROM previous_employment pe WHERE pe.employee_id = e.id) as previous_company
             FROM employees e
             WHERE e.personal_details->>'firstName' ILIKE $1
                OR e.personal_details->>'lastName' ILIKE $1
                OR e.email ILIKE $1`,
            [term]
        );
        res.json(result.rows);
    } catch (err) {
        next(err);
    }
});

app.use(errorHandler);

app.listen(port, () => {
    console.log(`Server running on http://16.171.33.65:${port}`);
});
